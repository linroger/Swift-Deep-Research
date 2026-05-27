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
        guard await context.budget.registerSource(for: context.workerID) else {
            return .failed(message: "Source cap reached for this worker")
        }

        let forceJS = args.javascript ?? false
        let session = self.session

        do {
            let fetched = try await context.cache.fetch(url) { resolved in
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
            context.emit(.sourceFetched(context.workerID, fetched))
            await context.charge(fetched.extractedText.count / 4)
            let payload = try JSONEncoder().encode(fetched)
            return .ok(summary: "Fetched \(url.host ?? "page") (\(fetched.extractedText.count) chars, \(fetched.strategy.rawValue))",
                       payloadJSON: String(decoding: payload, as: UTF8.self))
        } catch {
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
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<400) ~= http.statusCode,
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        let doc = try SwiftSoup.parse(html)
        try doc.select("script, style, nav, footer, header, aside, noscript, iframe").remove()
        let title = (try? doc.title()) ?? url.host ?? url.absoluteString
        let text = (try? doc.text()) ?? ""
        let cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // If a "page" comes back with <500 chars, the real content is probably JS-rendered.
        if cleaned.count < 500 { return nil }
        return Extracted(url: url, title: title, body: cleaned)
    }

    // MARK: - JavaScript fallback

    #if canImport(WebKit)
    @MainActor
    fileprivate final class HiddenWebView: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        private var continuation: CheckedContinuation<Void, Error>?

        override init() {
            let config = WKWebViewConfiguration()
            self.webView = WKWebView(frame: .zero, configuration: config)
            super.init()
            self.webView.navigationDelegate = self
        }

        func load(_ url: URL) async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.continuation = c
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                webView.load(request)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error); continuation = nil
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error); continuation = nil
        }
    }

    fileprivate static func extractJavaScript(url: URL) async throws -> Extracted {
        let host = await MainActor.run { HiddenWebView() }
        try await host.load(url)
        // Give late-loading scripts a beat to settle.
        try? await Task.sleep(for: .milliseconds(750))
        let title: String = try await MainActor.run {
            let dispatcher = WebViewJSDispatcher(webView: host.webView)
            return try awaitJSString(dispatcher: dispatcher, js: "document.title")
        }
        let body: String = try await MainActor.run {
            let dispatcher = WebViewJSDispatcher(webView: host.webView)
            return try awaitJSString(dispatcher: dispatcher,
                                     js: "(function(){var el=document.body.cloneNode(true);['script','style','nav','footer','header','aside','iframe','noscript'].forEach(function(t){Array.from(el.getElementsByTagName(t)).forEach(function(n){n.remove();});});return el.innerText;})();")
        }
        let cleaned = body
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Extracted(url: url, title: title, body: cleaned)
    }

    @MainActor
    fileprivate final class WebViewJSDispatcher {
        let webView: WKWebView
        init(webView: WKWebView) { self.webView = webView }
    }

    @MainActor
    fileprivate static func awaitJSString(dispatcher: WebViewJSDispatcher, js: String) throws -> String {
        // Synchronous bridge: we re-dispatch the evaluation on the main thread,
        // but since `WKWebView.evaluateJavaScript` is async, we wrap it.
        let semaphore = DispatchSemaphore(value: 0)
        var output: String = ""
        var caught: Error?
        dispatcher.webView.evaluateJavaScript(js) { result, error in
            if let error { caught = error }
            else if let str = result as? String { output = str }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        if let caught { throw caught }
        return output
    }
    #endif
}
