import Foundation
import SwiftSoup
#if canImport(WebKit)
import WebKit
#endif

/// Fetch + extract readable text from a URL.
///
/// Fast path: URLSession + SwiftSoup for static HTML. If the static body is
/// suspiciously empty (likely a React/Next/Vue SPA), falls back to a hidden
/// `WKWebView` that runs JavaScript and returns the rendered DOM.
public struct WebReaderTool: ResearchTool {
    public let spec = LLMToolSpec(
        name: "fetch_url",
        description: "Fetch the readable text content of a URL. Handles both static HTML and JavaScript-rendered pages.",
        parametersJSONSchema: #"""
        {
          "type": "object",
          "required": ["url"],
          "properties": {
            "url": { "type": "string", "description": "Absolute URL to fetch." },
            "javascript": {
              "type": "boolean",
              "default": false,
              "description": "Force JavaScript rendering even if static path succeeds."
            }
          }
        }
        """#
    )

    private let session: URLSession
    public init(session: URLSession = HTTPClientCommon.defaultSession(timeout: 45)) {
        self.session = session
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutcome {
        struct Args: Decodable { let url: String; let javascript: Bool? }
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: argumentsJSON.data(using: .utf8) ?? Data())
        } catch {
            return .failed(message: "fetch_url arguments invalid: \(error.localizedDescription)")
        }
        guard let url = URL(string: args.url) else {
            return .failed(message: "fetch_url: invalid URL")
        }
        if let reason = URLSafety.blockReason(for: url) {
            return .failed(message: "fetch_url: refusing to fetch \(url.absoluteString) — \(reason). Only public http(s) URLs are allowed.")
        }
        guard await context.budget.registerSource(for: context.workerID) else {
            return .failed(message: "Source cap reached for this worker")
        }

        let forceJS = args.javascript ?? false
        let session = self.session

        do {
            let (fetched, wasCached) = try await context.cache.fetch(url) { resolved in
                if !forceJS, let static_ = try await Self.extractStatic(url: resolved, session: session) {
                    return static_.asFetched(strategy: .staticHTML)
                }
                #if canImport(WebKit)
                let rendered = try await Self.extractJavaScript(url: resolved)
                return rendered.asFetched(strategy: .javascriptRendered)
                #else
                throw EngineFailure(kind: .toolFailure,
                                    message: "Static fetch yielded no content and WebKit fallback unavailable.")
                #endif
            }
            if wasCached {
                // Cache/in-flight hit: no new network fetch happened, so give back
                // the source slot we speculatively reserved and skip the token
                // charge (re-charging would double-count). Surface the dedup so
                // the wired-up UI can show the 'Cache hit' activity.
                await context.budget.releaseSource(for: context.workerID)
                context.emit(.sourceCacheHit(context.workerID, url))
            } else {
                context.emit(.sourceFetched(context.workerID, fetched))
                await context.charge(fetched.extractedText.count / 4)
            }
            let payload = try JSONEncoder().encode(fetched)
            return .ok(summary: "Fetched \(url.host ?? "page") (\(fetched.extractedText.count) chars, \(fetched.strategy.rawValue))",
                       payloadJSON: String(decoding: payload, as: UTF8.self))
        } catch {
            // Hand back the source slot we reserved so a failed fetch doesn't
            // permanently shrink this worker's source budget.
            await context.budget.releaseSource(for: context.workerID)
            return .failed(message: "All fetch strategies failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Static extraction

    fileprivate struct Extracted: Sendable {
        let url: URL
        let title: String
        let body: String

        func asFetched(strategy: FetchedSource.ExtractionStrategy) -> FetchedSource {
            FetchedSource(id: url.absoluteString,
                          url: url,
                          title: title,
                          extractedText: Clip.clip(body, to: 20_000),
                          strategy: strategy)
        }
    }

    fileprivate static func extractStatic(url: URL, session: URLSession) async throws -> Extracted? {
        var req = URLRequest(url: url)
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        // A realistic browser UA: many sites (Cloudflare, major news outlets)
        // serve 403/429 to non-browser agents, which silently emptied sources.
        req.setValue(HTTPClientCommon.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTPClientCommon.dataWithRetry(for: req, session: session, label: "fetch_url")
        guard let http = response as? HTTPURLResponse, (200..<400) ~= http.statusCode else {
            return nil
        }
        // Decode tolerantly: a large slice of the web isn't UTF-8 (Windows-1252,
        // ISO-8859-1, GB2312, Shift-JIS). Falling straight to `nil` on non-UTF-8
        // both lost the page and triggered the slower JS fallback unnecessarily.
        guard let html = Self.decodeHTML(data: data, response: http) else { return nil }
        let doc = try SwiftSoup.parse(html)
        try doc.select("script, style, nav, footer, header, aside, noscript, iframe").remove()
        let title = (try? doc.title()) ?? url.host ?? url.absoluteString
        let text = (try? doc.text()) ?? ""
        let cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Only treat a near-empty body as "probably JS-rendered" and fall back.
        // The old 500-char floor discarded many valid short pages (definitions,
        // abstracts, doc stubs) and then failed in the fallback. 200 keeps the
        // SPA heuristic while preserving concise real content.
        if cleaned.count < 200 { return nil }
        return Extracted(url: url, title: title, body: cleaned)
    }

    /// Decode an HTML body using the charset from the `Content-Type` header /
    /// `<meta charset>` when present, falling back through UTF-8 and finally
    /// ISO-8859-1 (which never fails) so non-UTF-8 pages still yield text.
    fileprivate static func decodeHTML(data: Data, response: HTTPURLResponse) -> String? {
        if data.isEmpty { return nil }
        var encodings: [String.Encoding] = []
        if let charset = response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .components(separatedBy: "charset=").last,
           !charset.isEmpty {
            let cfEnc = CFStringConvertIANACharSetNameToEncoding(charset.trimmingCharacters(in: .whitespaces) as CFString)
            if cfEnc != kCFStringEncodingInvalidId {
                encodings.append(String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc)))
            }
        }
        encodings.append(.utf8)
        encodings.append(.windowsCP1252)
        encodings.append(.isoLatin1)   // never fails — last resort
        for enc in encodings {
            if let s = String(data: data, encoding: enc), !s.isEmpty { return s }
        }
        return nil
    }

    // MARK: - JavaScript fallback

    #if canImport(WebKit)
    @MainActor
    fileprivate final class HiddenWebView: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        private var continuation: CheckedContinuation<Void, Error>?
        private var timeoutTask: Task<Void, Never>?

        override init() {
            let config = WKWebViewConfiguration()
            self.webView = WKWebView(frame: .zero, configuration: config)
            super.init()
            self.webView.navigationDelegate = self
        }

        func load(_ url: URL, timeout: Duration = .seconds(20)) async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.continuation = c
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                webView.load(request)
                // Overall watchdog. WKWebView navigation can hang indefinitely
                // (slow/looping JS, delegate callbacks that never fire), and
                // URLRequest.timeoutInterval is not reliably honored for
                // navigation — so without this the continuation would never
                // resume, leaking it and stalling the worker for the entire
                // wall-clock budget. On expiry we resume exactly once (via
                // `finish`) with a timeout error and stop the load.
                self.timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard let self, self.continuation != nil else { return }
                    self.webView.stopLoading()
                    self.finish(.failure(URLError(.timedOut)))
                }
            }
        }

        /// Resume the pending continuation exactly once and tear down the
        /// watchdog. Guards against the delegate-callback/timeout race and the
        /// double-resume that crashes a CheckedContinuation.
        private func finish(_ result: Result<Void, Error>) {
            timeoutTask?.cancel()
            timeoutTask = nil
            guard let c = continuation else { return }
            continuation = nil
            c.resume(with: result)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(.success(()))
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(.failure(error))
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(.failure(error))
        }

        /// Evaluate JS using the async API. The previous implementation blocked
        /// a cooperative-pool thread on a `DispatchSemaphore` waiting for a
        /// main-thread callback — a self-deadlock risk under Swift concurrency.
        func evalString(_ js: String) async -> String {
            do {
                let result = try await webView.evaluateJavaScript(js)
                return (result as? String) ?? ""
            } catch {
                return ""
            }
        }

        func stop() { webView.stopLoading() }
    }

    fileprivate static func extractJavaScript(url: URL) async throws -> Extracted {
        let host = await MainActor.run { HiddenWebView() }
        try await host.load(url)
        // Give late-loading scripts a beat to settle.
        try? await Task.sleep(for: .milliseconds(750))
        let title = await host.evalString("document.title")
        // Cap innerText in JS so a huge/infinite-scroll DOM can't pull megabytes
        // into a String (and then run a regex over all of it).
        let body = await host.evalString(
            "(function(){var b=document.body;if(!b){return '';}var el=b.cloneNode(true);['script','style','nav','footer','header','aside','iframe','noscript'].forEach(function(t){Array.from(el.getElementsByTagName(t)).forEach(function(n){n.remove();});});return (el.innerText||'').slice(0,200000);})();")
        await host.stop()
        let cleaned = body
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = title.isEmpty ? (url.host ?? url.absoluteString) : title
        return Extracted(url: url, title: resolvedTitle, body: cleaned)
    }
    #endif
}
