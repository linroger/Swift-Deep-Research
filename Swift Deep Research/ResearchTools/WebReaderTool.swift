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

    /// Hard ceiling on the HTML body we buffer + hand to SwiftSoup. A few MB is
    /// already an enormous page; beyond this a hostile/runaway response would
    /// spike memory and SwiftSoup parse time across the parallel workers. The
    /// rendered JS path caps innerText in-page (200k chars) instead.
    private static let maxHTMLBytes = 8 * 1024 * 1024

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
        // Reject an oversized HTML body before parsing it: SwiftSoup would
        // otherwise build a DOM for hundreds of MB, spiking memory/CPU across
        // the parallel workers. Treat over-cap pages as "no static content" so
        // the caller can decide (the JS path caps innerText in-page instead).
        let declaredLength = Int(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
        if max(declaredLength, data.count) > Self.maxHTMLBytes { return nil }
        // Decode tolerantly: a large slice of the web isn't UTF-8 (Windows-1252,
        // ISO-8859-1, GB2312, Shift-JIS). Falling straight to `nil` on non-UTF-8
        // both lost the page and triggered the slower JS fallback unnecessarily.
        guard let html = Self.decodeHTML(data: data, response: http) else { return nil }
        let doc = try SwiftSoup.parse(html)
        try doc.select("script, style, nav, footer, header, aside, noscript, iframe").remove()
        // Drop common boilerplate containers that survive the tag strip above
        // (comment threads, related-article rails, cookie banners, ad slots) so
        // they don't crowd out the article body in the 20k char budget.
        _ = try? doc.select(".comments, #comments, .related, .sidebar, [aria-label*=cookie], [id*=cookie], [class*=advert], [class*=newsletter]").remove()
        let title = (try? doc.title()) ?? url.host ?? url.absoluteString
        // Readability-lite: prefer the main-content container (<article>/<main>/
        // [role=main], else the densest <section>/<div>) over whole-body soup.
        // This raises signal-to-noise on news/blog/docs pages so the citation
        // extractor and synthesizer see the article rather than chrome.
        let text = (try? Self.mainContentText(in: doc)) ?? (try? doc.text()) ?? ""
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

    /// Lightweight readability heuristic: return the text of the page's main
    /// content container, or fall back to the whole-body text when no clear
    /// candidate stands out.
    ///
    /// Strategy (cheapest-first, no scoring of the whole tree):
    /// 1. Prefer the first semantic container — `<article>`, `<main>`, or
    ///    `[role=main]` — when it carries a substantial amount of text.
    /// 2. Otherwise pick the densest `<section>`/`<div>` whose text dominates the
    ///    page, but only when it clearly beats the rest (≥60% of body text), so a
    ///    layout wrapper that merely contains everything isn't mistaken for the
    ///    article.
    /// 3. Fall back to the full body text — never returns less content than a
    ///    naive `doc.text()` would on pages without a recognizable main region.
    fileprivate static func mainContentText(in doc: Document) throws -> String {
        let bodyText = try doc.text()
        let bodyLen = bodyText.count
        // Tiny pages (definitions, stubs): the whole body IS the content.
        guard bodyLen >= 400 else { return bodyText }

        for selector in ["article", "main", "[role=main]"] {
            if let el = try doc.select(selector).first() {
                let t = try el.text()
                // Require the semantic container to hold a meaningful share of the
                // page; some sites wrap a nav blurb in <main>.
                if t.count >= 200 && t.count >= bodyLen / 4 { return t }
            }
        }

        // Densest generic container, capped so we don't scan a pathological DOM.
        var best = ""
        for el in try doc.select("section, div").array().prefix(400) {
            let t = try el.text()
            if t.count > best.count { best = t }
        }
        if best.count >= (bodyLen * 6) / 10 { return best }
        return bodyText
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
            // Resource ceilings for rendering untrusted pages (the page runs
            // arbitrary remote JS to surface a client-rendered DOM):
            //  • Non-persistent store: no cookies/cache/local-storage survive the
            //    fetch, so one hostile page can't seed state for the next.
            //  • No media autoplay — avoids spinning up audio/video pipelines for
            //    a headless text extraction.
            // The hard wall-clock ceiling stays the 20s navigation watchdog in
            // load(...) plus the in-JS 200k-char innerText cap, so a page that
            // never settles can't stall the worker for the whole run budget.
            config.websiteDataStore = .nonPersistent()
            config.mediaTypesRequiringUserActionForPlayback = .all
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
