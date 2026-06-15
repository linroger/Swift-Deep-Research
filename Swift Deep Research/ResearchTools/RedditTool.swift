import Foundation

/// Reddit search + thread reader via the public `www.reddit.com/.json` endpoint.
///
/// Two modes:
///   - `mode: "search"` — searches Reddit globally or within a subreddit.
///   - `mode: "thread"` — pulls the post + top comments for a thread URL.
///
/// Reddit is a uniquely valuable source for product reviews, niche
/// communities, and "what do users actually think" questions. The unauth'd
/// JSON endpoint rate-limits aggressively, so this tool sends a descriptive
/// User-Agent and falls back to a friendly error rather than retrying.
public struct RedditTool: ResearchTool {
    public let spec = LLMToolSpec(
        name: "reddit",
        description: "Search Reddit or read a Reddit thread (post + top comments). Useful for user opinions, product reviews, niche community discussions.",
        parametersJSONSchema: #"""
        {
          "type": "object",
          "required": ["mode"],
          "properties": {
            "mode": { "type": "string", "enum": ["search", "thread"], "description": "search for posts; thread to read a specific discussion." },
            "query": { "type": "string", "description": "Search terms (search mode)." },
            "subreddit": { "type": "string", "description": "Optional subreddit to scope the search to (without r/)." },
            "url": { "type": "string", "description": "Reddit thread URL (thread mode)." },
            "limit": { "type": "integer", "default": 10, "description": "Max results (search mode) or comments (thread mode)." }
          }
        }
        """#
    )

    private let session: URLSession
    public init(session: URLSession = HTTPClientCommon.defaultSession(timeout: 25)) {
        self.session = session
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutcome {
        struct Args: Decodable {
            let mode: String
            let query: String?
            let subreddit: String?
            let url: String?
            let limit: Int?
        }
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return .failed(message: "reddit: invalid arguments")
        }
        switch args.mode.lowercased() {
        case "search":
            guard let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                return .failed(message: "reddit search: query required")
            }
            return try await search(query: query,
                                    subreddit: args.subreddit,
                                    limit: max(1, min(args.limit ?? 10, 25)),
                                    context: context)
        case "thread":
            guard let urlString = args.url, let url = URL(string: urlString) else {
                return .failed(message: "reddit thread: url required")
            }
            if let reason = URLSafety.blockReason(for: url) {
                return .failed(message: "reddit thread: refusing to fetch \(url.absoluteString) — \(reason).")
            }
            return try await thread(url: url,
                                    limit: max(1, min(args.limit ?? 10, 50)),
                                    context: context)
        default:
            return .failed(message: "reddit: unknown mode \(args.mode)")
        }
    }

    // MARK: - Search

    /// Subreddit names are limited to ASCII letters, digits, and underscore
    /// (Reddit's own rule). The LLM controls `args.subreddit`, so we validate it
    /// against this charset before it ever touches the URL path — see
    /// `sec-reddit-subreddit-injection-7`. Without this, a value like
    /// `foo?x=1`, `foo#frag`, or `foo/../../x` is concatenated into the base
    /// string *before* `URLComponents(string:)` parses it, which lets the
    /// untrusted value alter the path/query/fragment of the request.
    private static let subredditAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")

    private func search(query: String, subreddit: String?, limit: Int, context: ToolContext) async throws -> ToolOutcome {
        // Build the components on a fixed base, then set the path structurally so
        // the subreddit can never re-parse into a different path/query/host.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.reddit.com"
        var restrictToSub = false
        if let raw = subreddit?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let sub = raw.hasPrefix("r/") ? String(raw.dropFirst(2)) : raw   // tolerate a leading "r/"
            guard sub.count <= 50,
                  sub.unicodeScalars.allSatisfy({ Self.subredditAllowed.contains($0) }) else {
                return .failed(message: "reddit search: invalid subreddit '\(raw)' (letters, digits, and underscore only)")
            }
            // `path` performs its own percent-encoding, and the validated charset
            // contains no path/query/fragment delimiters regardless.
            components.path = "/r/\(sub)/search.json"
            restrictToSub = true
        } else {
            components.path = "/search.json"
        }
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "relevance"),
            URLQueryItem(name: "type", value: "link")
        ]
        if restrictToSub { items.append(URLQueryItem(name: "restrict_sr", value: "true")) }
        components.queryItems = items
        guard let url = components.url, url.host?.lowercased() == "www.reddit.com" else {
            return .failed(message: "reddit: bad URL")
        }
        // Defense in depth: the constructed URL is LLM-influenced, so run it
        // through the shared SSRF guard before issuing the request.
        if let reason = URLSafety.blockReason(for: url) {
            return .failed(message: "reddit search: refusing to fetch \(url.absoluteString) — \(reason).")
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(HTTPClientCommon.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTPClientCommon.dataWithRetry(for: req, session: session, label: "reddit_search")
        guard let http = response as? HTTPURLResponse, (200..<300) ~= http.statusCode else {
            return .failed(message: "reddit search: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) (Reddit rate-limits the public endpoint; try again or use web_search).")
        }

        struct Listing: Decodable {
            struct Container: Decodable { let data: Inner }
            struct Inner: Decodable { let children: [Wrapper] }
            struct Wrapper: Decodable { let data: PostData }
            struct PostData: Decodable {
                let id: String
                let title: String
                let permalink: String
                let subreddit: String
                let selftext: String?
                let score: Int
                let num_comments: Int
                let author: String
            }
            let data: Inner
        }
        let env = try JSONDecoder().decode(Listing.self, from: data)
        var discovered: [DiscoveredSource] = []
        for w in env.data.children {
            let post = w.data
            guard let pageURL = URL(string: "https://www.reddit.com\(post.permalink)") else { continue }
            let snippet = "r/\(post.subreddit) • u/\(post.author) • \(post.score) pts • \(post.num_comments) comments\n\(Clip.clip(post.selftext ?? "", to: 240))"
            let d = DiscoveredSource(id: "reddit-\(post.id)",
                                     title: post.title,
                                     url: pageURL,
                                     snippet: snippet,
                                     provider: "reddit")
            discovered.append(d)
            context.emit(.sourceDiscovered(context.workerID, d))
        }
        let payload = try JSONEncoder().encode(discovered)
        return .ok(summary: "Reddit: \(discovered.count) posts for \(query)",
                   payloadJSON: String(decoding: payload, as: UTF8.self))
    }

    // MARK: - Thread

    private func thread(url: URL, limit: Int, context: ToolContext) async throws -> ToolOutcome {
        // Convert "/r/foo/comments/abc/title" to "/r/foo/comments/abc/title.json".
        var jsonURL = url
        if !url.absoluteString.hasSuffix(".json") {
            jsonURL = URL(string: url.absoluteString.appending(".json")) ?? url
        }
        guard await context.budget.registerSource(for: context.workerID) else {
            return .failed(message: "Source cap reached for this worker")
        }
        let session = self.session
        let fetched: FetchedSource
        let wasCached: Bool
        do {
            (fetched, wasCached) = try await context.cache.fetch(jsonURL) { resolved in
                var req = URLRequest(url: resolved)
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                req.setValue(HTTPClientCommon.browserUserAgent, forHTTPHeaderField: "User-Agent")
                let (data, response) = try await HTTPClientCommon.dataWithRetry(for: req, session: session, label: "reddit_thread")
                guard let http = response as? HTTPURLResponse, (200..<300) ~= http.statusCode else {
                    throw EngineFailure(kind: .toolFailure,
                                        message: "reddit thread: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                return try Self.flatten(data: data, url: url, limit: limit)
            }
        } catch {
            await context.budget.releaseSource(for: context.workerID)
            return .failed(message: "reddit thread failed: \(error.localizedDescription)")
        }
        if wasCached {
            // Cache/in-flight hit: no new request happened, so give back the
            // reserved source slot and skip the token charge (re-charging would
            // double-count), then surface the dedup to the UI.
            await context.budget.releaseSource(for: context.workerID)
            context.emit(.sourceCacheHit(context.workerID, url))
        } else {
            context.emit(.sourceFetched(context.workerID, fetched))
            await context.charge(fetched.extractedText.count / 4)
        }
        let payload = try JSONEncoder().encode(fetched)
        return .ok(summary: "Reddit thread: \(fetched.title) (\(fetched.extractedText.count) chars)",
                   payloadJSON: String(decoding: payload, as: UTF8.self))
    }

    private static func flatten(data: Data, url: URL, limit: Int) throws -> FetchedSource {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2,
              let postContainer = (json[0] as? [String: Any])?["data"] as? [String: Any],
              let postChildren = postContainer["children"] as? [[String: Any]],
              let postData = (postChildren.first?["data"]) as? [String: Any],
              let commentContainer = (json[1] as? [String: Any])?["data"] as? [String: Any],
              let commentChildren = commentContainer["children"] as? [[String: Any]] else {
            throw EngineFailure(kind: .toolFailure, message: "reddit: unexpected response shape")
        }
        let title = (postData["title"] as? String) ?? url.lastPathComponent
        let selfText = (postData["selftext"] as? String) ?? ""
        let author = (postData["author"] as? String) ?? "?"
        let score = (postData["score"] as? Int) ?? 0
        var combined = "# \(title)\nu/\(author) • \(score) pts\n\n\(selfText)\n\n---\n\n## Top comments\n"

        var taken = 0
        for wrapper in commentChildren where taken < limit {
            guard let cdata = wrapper["data"] as? [String: Any],
                  let body = cdata["body"] as? String,
                  !body.isEmpty else { continue }
            let cauthor = (cdata["author"] as? String) ?? "?"
            let cscore = (cdata["score"] as? Int) ?? 0
            combined += "\n**u/\(cauthor)** • \(cscore) pts\n\(body)\n"
            taken += 1
        }
        return FetchedSource(id: url.absoluteString,
                             url: url,
                             title: title,
                             extractedText: Clip.clip(combined, to: 25_000),
                             strategy: .reddit)
    }
}
