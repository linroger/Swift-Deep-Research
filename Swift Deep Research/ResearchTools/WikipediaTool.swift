import Foundation

/// Wikipedia REST search + summary.
///
/// Uses the public `en.wikipedia.org/api/rest_v1` endpoints (no auth required).
/// Two operations are exposed under one tool to keep the worker's tool list small:
///   - `mode: "search"` — full-text article search returning titles + snippets.
///   - `mode: "summary"` — pulls the canonical lead-paragraph summary for an article.
///
/// Wikipedia is often the single most efficient first stop for biographical,
/// historical, and reference questions; surfacing it as its own tool lets the
/// planner cite it directly instead of going through a generic web search.
public struct WikipediaTool: ResearchTool {
    public let spec = LLMToolSpec(
        name: "wikipedia",
        description: "Search Wikipedia or fetch the canonical summary of a known article. Use mode=search for discovery, mode=summary when you know the article title.",
        parametersJSONSchema: #"""
        {
          "type": "object",
          "required": ["mode", "query"],
          "properties": {
            "mode": { "type": "string", "enum": ["search", "summary"], "description": "search returns hits; summary returns one article's lead." },
            "query": { "type": "string", "description": "Search terms or canonical article title." },
            "limit": { "type": "integer", "default": 5, "description": "Max search results (search mode only)." }
          }
        }
        """#
    )

    private let session: URLSession
    public init(session: URLSession = HTTPClientCommon.defaultSession(timeout: 20)) {
        self.session = session
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutcome {
        struct Args: Decodable { let mode: String; let query: String; let limit: Int? }
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return .failed(message: "wikipedia: invalid arguments")
        }
        let trimmed = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed(message: "wikipedia: empty query") }

        switch args.mode.lowercased() {
        case "search":
            return try await search(query: trimmed, limit: args.limit ?? 5, context: context)
        case "summary":
            return try await summary(title: trimmed, context: context)
        default:
            return .failed(message: "wikipedia: unknown mode \(args.mode)")
        }
    }

    private func search(query: String, limit: Int, context: ToolContext) async throws -> ToolOutcome {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: String(max(1, min(limit, 10)))),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "origin", value: "*")
        ]
        guard let url = components.url else { return .failed(message: "wikipedia: bad URL") }
        let (data, response) = try await HTTPClientCommon.dataWithRetry(for: URLRequest(url: url), session: session, label: "wikipedia_search")
        guard let http = response as? HTTPURLResponse, (200..<300) ~= http.statusCode else {
            return .failed(message: "wikipedia: HTTP \(string(of: response))")
        }
        struct Envelope: Decodable {
            struct Query: Decodable { let search: [Hit] }
            struct Hit: Decodable {
                let title: String
                let snippet: String
                let pageid: Int
            }
            let query: Query
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        var emitted: [DiscoveredSource] = []
        for hit in env.query.search {
            let cleanedSnippet = hit.snippet
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let titleForURL = hit.title.replacingOccurrences(of: " ", with: "_")
            guard let pageURL = URL(string: "https://en.wikipedia.org/wiki/\(titleForURL.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? titleForURL)") else { continue }
            let discovered = DiscoveredSource(id: "wiki-\(hit.pageid)",
                                              title: hit.title,
                                              url: pageURL,
                                              snippet: cleanedSnippet,
                                              provider: "wikipedia")
            emitted.append(discovered)
            context.emit(.sourceDiscovered(context.workerID, discovered))
        }
        let payload = try JSONEncoder().encode(emitted)
        return .ok(summary: "Wikipedia: \(emitted.count) hits for \(query)",
                   payloadJSON: String(decoding: payload, as: UTF8.self))
    }

    private func summary(title: String, context: ToolContext) async throws -> ToolOutcome {
        let titleForURL = title.replacingOccurrences(of: " ", with: "_")
        guard let encoded = titleForURL.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else {
            return .failed(message: "wikipedia: bad title")
        }
        guard await context.budget.registerSource(for: context.workerID) else {
            return .failed(message: "Source cap reached for this worker")
        }
        let session = self.session
        let fetched: FetchedSource
        do {
            fetched = try await context.cache.fetch(url) { resolved in
                var req = URLRequest(url: resolved)
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await HTTPClientCommon.dataWithRetry(for: req, session: session, label: "wikipedia_summary")
                guard let http = response as? HTTPURLResponse, (200..<300) ~= http.statusCode else {
                    throw EngineFailure(kind: .toolFailure,
                                        message: "wikipedia summary: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                struct Envelope: Decodable {
                    let title: String
                    let extract: String
                    let content_urls: ContentURLs?
                    struct ContentURLs: Decodable { let desktop: Desktop }
                    struct Desktop: Decodable { let page: String }
                }
                let env = try JSONDecoder().decode(Envelope.self, from: data)
                let canonical = URL(string: env.content_urls?.desktop.page ?? resolved.absoluteString) ?? resolved
                return FetchedSource(id: canonical.absoluteString,
                                     url: canonical,
                                     title: env.title,
                                     extractedText: env.extract,
                                     strategy: .staticHTML)
            }
        } catch {
            await context.budget.releaseSource(for: context.workerID)
            return .failed(message: "wikipedia summary failed: \(error.localizedDescription)")
        }
        context.emit(.sourceFetched(context.workerID, fetched))
        await context.charge(fetched.extractedText.count / 4)
        let payload = try JSONEncoder().encode(fetched)
        return .ok(summary: "Wikipedia summary: \(fetched.title) (\(fetched.extractedText.count) chars)",
                   payloadJSON: String(decoding: payload, as: UTF8.self))
    }

    private func string(of response: URLResponse) -> String {
        if let http = response as? HTTPURLResponse { return String(http.statusCode) }
        return "unknown"
    }
}
