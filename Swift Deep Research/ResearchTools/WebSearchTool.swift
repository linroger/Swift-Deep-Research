import Foundation

/// Multi-provider web search with a built-in fallback chain.
///
/// Providers in priority order: Tavily (agent-optimized) → Exa (semantic) →
/// Brave (general) → DuckDuckGo (no key, last resort). The first one that
/// returns ≥1 result wins. Results carry a `provider` tag so the UI can show
/// where the citation came from.
///
/// Backend failures are collected per-attempt and surfaced in the `.failed`
/// outcome so the LLM (and the activity feed) sees *why* search failed — a
/// 401 from Tavily, a 429 from Exa, a decoding error from Brave — instead of
/// the previous generic "no results" sink that hid configuration mistakes.
public struct WebSearchTool: ResearchTool {
    public let spec = LLMToolSpec(
        name: "web_search",
        description: "Search the web for current information. Returns titles, URLs, and short snippets.",
        parametersJSONSchema: #"""
        {
          "type": "object",
          "required": ["query"],
          "properties": {
            "query": { "type": "string", "description": "Search query." },
            "limit": { "type": "integer", "minimum": 1, "maximum": 12, "default": 6 }
          }
        }
        """#
    )

    private let backends: [any SearchBackend]
    private let session: URLSession

    public init(backends: [any SearchBackend], session: URLSession = HTTPClientCommon.defaultSession(timeout: 30)) {
        self.backends = backends
        self.session = session
    }

    /// Build the default fallback chain from whatever API keys are configured.
    public static func makeDefault() async -> WebSearchTool {
        let store = KeychainStore.shared
        var backends: [any SearchBackend] = []
        if let key = await store.get(.tavily), !key.isEmpty {
            backends.append(TavilyBackend(apiKey: key))
        }
        if let key = await store.get(.exa), !key.isEmpty {
            backends.append(ExaBackend(apiKey: key))
        }
        if let key = await store.get(.brave), !key.isEmpty {
            backends.append(BraveBackend(apiKey: key))
        }
        backends.append(DuckDuckGoBackend())
        Log.tool.debug("web_search initialized with \(backends.count, privacy: .public) backend(s): \(backends.map(\.providerID).joined(separator: ", "), privacy: .public)")
        return WebSearchTool(backends: backends)
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutcome {
        struct Args: Decodable { let query: String; let limit: Int? }
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self,
                                            from: argumentsJSON.data(using: .utf8) ?? Data())
        } catch {
            return .failed(message: "web_search arguments invalid: \(error.localizedDescription)")
        }
        let limit = min(max(args.limit ?? 6, 1), 12)

        var failures: [String] = []
        for backend in backends {
            do {
                let results = try await backend.search(query: args.query, limit: limit, session: session)
                if !results.isEmpty {
                    for result in results {
                        context.emit(.sourceDiscovered(context.workerID, result))
                    }
                    let payload = SearchResultsPayload(query: args.query,
                                                      provider: backend.providerID,
                                                      results: results)
                    let payloadData = try JSONEncoder().encode(payload)
                    let payloadJSON = String(decoding: payloadData, as: UTF8.self)
                    let summary = "\(backend.providerID): \(results.count) result(s) for “\(args.query)”"
                    await context.charge(payloadJSON.count / 4)
                    return .ok(summary: summary, payloadJSON: payloadJSON)
                } else {
                    failures.append("\(backend.providerID): empty result set")
                }
            } catch {
                let msg = "\(backend.providerID): \(error.localizedDescription)"
                Log.tool.warning("\(msg, privacy: .public)")
                failures.append(msg)
                continue
            }
        }
        let detail = failures.isEmpty ? "no backends configured" : failures.joined(separator: "; ")
        return .failed(message: "All search backends failed for “\(args.query)”. \(detail)")
    }
}

// MARK: - Backend protocol

public protocol SearchBackend: Sendable {
    var providerID: String { get }
    func search(query: String, limit: Int, session: URLSession) async throws -> [DiscoveredSource]
}

public struct SearchResultsPayload: Codable, Sendable {
    public let query: String
    public let provider: String
    public let results: [DiscoveredSource]
}

/// Translate non-2xx HTTP responses into informative errors. Without this
/// each backend would let a 401/403/429 fall through to `JSONDecoder` where
/// the parsing error would mask the real cause (bad key, rate limit, etc.).
private struct SearchHTTPError: LocalizedError {
    let provider: String
    let status: Int
    let body: String
    var errorDescription: String? {
        let snippet = body.replacingOccurrences(of: "\n", with: " ")
                          .trimmingCharacters(in: .whitespaces)
                          .prefix(200)
        return "HTTP \(status) — \(snippet.isEmpty ? "no body" : String(snippet))"
    }
}

private func validate(_ response: URLResponse,
                      data: Data,
                      provider: String) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard !(200..<300).contains(http.statusCode) else { return }
    let body = String(data: data, encoding: .utf8) ?? ""
    throw SearchHTTPError(provider: provider, status: http.statusCode, body: body)
}

// MARK: - Tavily

public struct TavilyBackend: SearchBackend {
    public let providerID = "tavily"
    private let apiKey: String

    public init(apiKey: String) { self.apiKey = apiKey }

    public func search(query: String, limit: Int, session: URLSession) async throws -> [DiscoveredSource] {
        var req = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        struct Body: Encodable {
            let query: String
            let max_results: Int
            let search_depth: String
            let include_answer: Bool
        }
        req.httpBody = try JSONEncoder().encode(Body(query: query,
                                                     max_results: limit,
                                                     search_depth: "advanced",
                                                     include_answer: false))
        let (data, response) = try await session.data(for: req)
        try validate(response, data: data, provider: providerID)
        struct Resp: Decodable {
            struct Result: Decodable {
                let title: String
                let url: String
                let content: String?
            }
            let results: [Result]
        }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        return resp.results.compactMap { r in
            guard let u = URL(string: r.url) else { return nil }
            return DiscoveredSource(title: r.title, url: u, snippet: r.content, provider: "tavily")
        }
    }
}

// MARK: - Exa

public struct ExaBackend: SearchBackend {
    public let providerID = "exa"
    private let apiKey: String

    public init(apiKey: String) { self.apiKey = apiKey }

    public func search(query: String, limit: Int, session: URLSession) async throws -> [DiscoveredSource] {
        var req = URLRequest(url: URL(string: "https://api.exa.ai/search")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        // Exa's /search supports two `type`s: "neural" (semantic) and
        // "keyword". Neural is best for research-style queries but can
        // 422 when the API key tier doesn't include semantic search. We
        // request neural and let the validate() helper surface the real
        // error message instead of failing silently.
        struct Body: Encodable {
            let query: String
            let numResults: Int
            let useAutoprompt: Bool
            let type: String
        }
        req.httpBody = try JSONEncoder().encode(Body(query: query,
                                                     numResults: limit,
                                                     useAutoprompt: true,
                                                     type: "neural"))
        let (data, response) = try await session.data(for: req)
        try validate(response, data: data, provider: providerID)
        struct Resp: Decodable {
            struct Result: Decodable {
                let title: String?
                let url: String
                let text: String?
            }
            let results: [Result]
        }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        return resp.results.compactMap { r in
            guard let u = URL(string: r.url) else { return nil }
            return DiscoveredSource(title: r.title ?? r.url,
                                    url: u,
                                    snippet: r.text,
                                    provider: "exa")
        }
    }
}

// MARK: - Brave

public struct BraveBackend: SearchBackend {
    public let providerID = "brave"
    private let apiKey: String

    public init(apiKey: String) { self.apiKey = apiKey }

    public func search(query: String, limit: Int, session: URLSession) async throws -> [DiscoveredSource] {
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        var req = URLRequest(url: URL(string: "https://api.search.brave.com/res/v1/web/search?q=\(escaped)&count=\(limit)")!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        let (data, response) = try await session.data(for: req)
        try validate(response, data: data, provider: providerID)
        struct Resp: Decodable {
            struct Web: Decodable {
                struct Result: Decodable {
                    let title: String
                    let url: String
                    let description: String?
                }
                let results: [Result]?
            }
            let web: Web?
        }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        return (resp.web?.results ?? []).compactMap { r in
            guard let u = URL(string: r.url) else { return nil }
            return DiscoveredSource(title: r.title, url: u, snippet: r.description, provider: "brave")
        }
    }
}

// MARK: - DuckDuckGo (HTML fallback, no key required)

public struct DuckDuckGoBackend: SearchBackend {
    public let providerID = "ddg"

    public init() {}

    public func search(query: String, limit: Int, session: URLSession) async throws -> [DiscoveredSource] {
        // Percent-encode the whole query: the old whitespace→`+` join left `&`,
        // `#`, `?`, `/` unescaped, which broke the URL for many real queries.
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? query.components(separatedBy: .whitespacesAndNewlines).joined(separator: "+")
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(escaped)") else { return [] }
        var req = URLRequest(url: url)
        req.setValue(HTTPClientCommon.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTPClientCommon.dataWithRetry(for: req, session: session, label: "ddg")
        try validate(response, data: data, provider: providerID)
        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return [] }
        // Cheap regex on result links — avoids a SwiftSoup dependency in this path.
        let pattern = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(html.startIndex..., in: html)
        var out: [DiscoveredSource] = []
        regex.enumerateMatches(in: html, range: range) { match, _, stop in
            guard let m = match, let hrefRange = Range(m.range(at: 1), in: html),
                  let titleRange = Range(m.range(at: 2), in: html) else { return }
            var href = String(html[hrefRange])
            if href.hasPrefix("//") { href = "https:" + href }
            href = resolveDDGRedirect(href)
            let title = stripHTML(String(html[titleRange]))
            if let u = URL(string: href) {
                out.append(DiscoveredSource(title: title, url: u, snippet: nil, provider: "ddg"))
                // Actually stop the enumeration once we have enough (the old
                // `return` only exited the closure for one match).
                if out.count >= limit { stop.pointee = true }
            }
        }
        return Array(out.prefix(limit))
    }

    private func resolveDDGRedirect(_ url: String) -> String {
        guard let components = URLComponents(string: url),
              components.host?.contains("duckduckgo.com") == true,
              let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value else {
            return url
        }
        return uddg
    }

    private func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
