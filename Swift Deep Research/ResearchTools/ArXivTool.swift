import Foundation

/// arXiv search via the public Atom feed at `export.arxiv.org/api/query`.
///
/// Returns the top N papers as `DiscoveredSource` records pointing at the
/// canonical arxiv abstract page. Workers can then call `fetch_url` to read
/// the abstract HTML or `read_pdf` to ingest the full PDF.
public struct ArXivTool: ResearchTool {
    public let spec = LLMToolSpec(
        name: "arxiv_search",
        description: "Search the arXiv preprint archive. Best for scientific, ML, math, physics, CS questions. Returns paper titles, authors, abstracts, and links.",
        parametersJSONSchema: #"""
        {
          "type": "object",
          "required": ["query"],
          "properties": {
            "query": { "type": "string", "description": "Free-form arXiv query. Supports arXiv's search syntax (ti:, au:, abs:, cat:)." },
            "limit": { "type": "integer", "default": 8, "description": "Maximum results to return (1–25)." },
            "sortBy": { "type": "string", "enum": ["relevance", "recent"], "default": "relevance" }
          }
        }
        """#
    )

    private let session: URLSession
    public init(session: URLSession = HTTPClientCommon.defaultSession(timeout: 20)) {
        self.session = session
    }

    /// arXiv's API terms ask for a descriptive User-Agent that identifies the
    /// client and a contact. Without it requests inherit the generic session UA
    /// and are more likely to be throttled.
    private static let userAgent =
        "SwiftDeepResearch/2.0 (arXiv API client; +https://github.com/swift-deep-research)"

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutcome {
        struct Args: Decodable { let query: String; let limit: Int?; let sortBy: String? }
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return .failed(message: "arxiv_search: invalid arguments")
        }
        let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .failed(message: "arxiv_search: empty query") }
        let limit = max(1, min(args.limit ?? 8, 25))
        let sortBy = (args.sortBy ?? "relevance").lowercased()

        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "search_query", value: query),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "max_results", value: String(limit))
        ]
        if sortBy == "recent" {
            items.append(URLQueryItem(name: "sortBy", value: "submittedDate"))
            items.append(URLQueryItem(name: "sortOrder", value: "descending"))
        }
        components.queryItems = items
        guard let url = components.url else { return .failed(message: "arxiv_search: bad URL") }

        // arXiv asks API clients to (a) identify themselves with a descriptive
        // User-Agent including a contact, and (b) stay under ~1 request/3s. With
        // up to ~6 workers fanning out we can blow past that and get throttled,
        // so we serialize arXiv calls through a process-wide ~3s rate gate.
        await ArXivRateLimiter.shared.waitForSlot()
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (atom, response) = try await HTTPClientCommon.dataWithRetry(for: request, session: session, label: "arxiv_search")
        guard let http = response as? HTTPURLResponse, (200..<300) ~= http.statusCode else {
            return .failed(message: "arxiv_search: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let entries = AtomParser.parse(data: atom)
        // arXiv returns HTTP 200 with a valid-but-empty Atom feed for queries
        // whose syntax it can't satisfy (e.g. a malformed field prefix), so 0
        // entries is ambiguous between "no matches" and "bad query". Surface a
        // syntax hint instead of a silent empty success so the worker can refine.
        if entries.isEmpty {
            return .ok(summary: "arXiv: 0 papers for \(query) — try simpler terms or arXiv field prefixes (ti:, au:, abs:, cat:).",
                       payloadJSON: "[]")
        }
        var discovered: [DiscoveredSource] = []
        for entry in entries {
            guard let pageURL = URL(string: entry.absURL) else { continue }
            let snippet = "\(entry.authors.joined(separator: ", "))\n\(entry.summary)"
            let d = DiscoveredSource(id: entry.id,
                                     title: entry.title,
                                     url: pageURL,
                                     snippet: Clip.clip(snippet, to: 600),
                                     provider: "arxiv")
            discovered.append(d)
            context.emit(.sourceDiscovered(context.workerID, d))
        }
        let payload = try JSONEncoder().encode(discovered)
        return .ok(summary: "arXiv: \(discovered.count) papers for \(query)",
                   payloadJSON: String(decoding: payload, as: UTF8.self))
    }
}

/// Process-wide courtesy rate limiter for the arXiv API.
///
/// arXiv asks clients not to issue more than roughly one request every three
/// seconds. Because every worker shares this one endpoint, a single shared gate
/// is enough: each caller awaits until at least `minInterval` has elapsed since
/// the previous granted slot, then records its own slot time. Serializing here
/// trades a little fan-out latency for not getting the whole run throttled.
private actor ArXivRateLimiter {
    static let shared = ArXivRateLimiter()
    private let minInterval: Duration = .seconds(3)
    /// The instant the *next* request is allowed to proceed. Reserved
    /// synchronously (before any `await`) so concurrent callers each claim a
    /// distinct, increasing slot rather than all reading the same stale value
    /// across the actor reentrancy that `Task.sleep` introduces.
    private var nextAllowed: ContinuousClock.Instant = .now

    func waitForSlot() async {
        let now = ContinuousClock.now
        let scheduled = max(now, nextAllowed)
        // Reserve the slot after this one *before* awaiting, so the next caller
        // computes its time relative to ours and they fan out by minInterval.
        nextAllowed = scheduled.advanced(by: minInterval)
        let delay = now.duration(to: scheduled)
        if delay > .zero { try? await Task.sleep(for: delay) }
    }
}

/// Minimal Atom feed parser tuned for arXiv's response format.
/// Uses `XMLParser` rather than pulling in a heavier dependency.
private enum AtomParser {
    struct Entry: Sendable {
        var id: String = ""
        var title: String = ""
        var summary: String = ""
        var absURL: String = ""
        var authors: [String] = []
    }

    static func parse(data: Data) -> [Entry] {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    final class Delegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var current: Entry?
        private var elementStack: [String] = []
        private var buffer = ""
        private var authorBuffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            elementStack.append(elementName)
            if elementName == "entry" { current = Entry() }
            if elementName == "link", let rel = attributeDict["rel"], rel == "alternate",
               let href = attributeDict["href"], current != nil {
                current?.absURL = href
            }
            buffer = ""
            if elementName == "author" { authorBuffer = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            guard current != nil else {
                elementStack.removeLast(); return
            }
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "id" where elementStack.contains("entry"):
                current?.id = trimmed
                if current?.absURL.isEmpty == true { current?.absURL = trimmed }
            case "title" where elementStack.contains("entry"):
                current?.title = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            case "summary":
                current?.summary = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            case "name" where elementStack.contains("author"):
                authorBuffer = trimmed
            case "author":
                if !authorBuffer.isEmpty { current?.authors.append(authorBuffer) }
            case "entry":
                if let c = current { entries.append(c) }
                current = nil
            default: break
            }
            elementStack.removeLast()
            buffer = ""
        }
    }
}
