import Foundation
import OSLog

/// Module-level logger handles. Use the subsystem reverse-DNS for filtering in Console.app.
public enum Log {
    public static let subsystem = "com.aryamirsepasi.Swift-Deep-Research"

    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let provider = Logger(subsystem: subsystem, category: "provider")
    public static let tool = Logger(subsystem: subsystem, category: "tool")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let net = Logger(subsystem: subsystem, category: "net")
}

/// Small helpers we use everywhere.
public enum Clip {
    /// Truncate to ~n chars, marking the cut so callers don't think the source ended.
    public static func clip(_ s: String, to n: Int) -> String {
        guard s.count > n else { return s }
        let prefix = s.prefix(n)
        return "\(prefix)…[clipped \(s.count - n) chars]"
    }
}

/// URLSession delegate that re-runs the SSRF guard on every HTTP redirect.
///
/// `URLSafety.blockReason(for:)` is enforced by each research tool on the URL
/// it was *handed*, but a public URL can `30x` → `http://169.254.169.254/`,
/// `http://127.0.0.1:5001`, or another private host. Default URLSession redirect
/// handling would follow that hop without re-validation, re-opening the exact
/// SSRF vector the up-front check closes. This delegate cancels (resumes with a
/// `nil` request) any redirect whose target is blocked, and passes safe public
/// redirects through unchanged. Stateless and `Sendable` so one instance can
/// back many concurrent sessions/tasks.
final class RedirectSafetyDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url else {
            // No destination URL to validate — refuse rather than follow blindly.
            completionHandler(nil)
            return
        }
        if let reason = URLSafety.blockReason(for: url) {
            Log.net.warning("Blocked SSRF redirect to \(url.absoluteString, privacy: .public): \(reason, privacy: .public)")
            completionHandler(nil)   // Cancel the redirect; the task fails fast.
            return
        }
        completionHandler(request)   // Safe public redirect: follow it.
    }
}

public enum HTTPClientCommon {
    public static let defaultUserAgent =
        "SwiftDeepResearch/2.0 (macOS) URLSession"

    /// A realistic desktop-Safari User-Agent for *web scraping* (page/PDF/Reddit
    /// fetches). Many sites (Cloudflare, major news outlets) return 403/429 to
    /// non-browser agents, which silently emptied web sources. LLM provider
    /// clients keep `defaultUserAgent`; only the research web tools use this.
    public static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// Build a URLSession.
    ///
    /// - `timeout` is `timeoutIntervalForRequest`: the inactivity window
    ///   *between* received data packets (it resets on every byte). This is the
    ///   correct liveness guard for streaming LLM responses and the only thing
    ///   that should bound a slow first token.
    /// - `resourceTimeout` is `timeoutIntervalForResource`: the hard ceiling on
    ///   the *entire* request lifetime. For streaming this must be large — the
    ///   old `timeout * 2` formula silently capped long deep-research streams
    ///   (e.g. 600s for a 300s request timeout) and killed reasoning models
    ///   mid-synthesis with "The network connection was lost". Default to ~24h
    ///   so only the inactivity window governs liveness.
    /// Shared, stateless redirect guard. `URLSession` retains its delegate until
    /// the session is invalidated; reusing one instance avoids re-allocating it
    /// for every session built here while keeping the SSRF re-validation on the
    /// redirect path for all research-tool fetches.
    private static let redirectGuard = RedirectSafetyDelegate()

    public static func defaultSession(timeout: TimeInterval = 30,
                                      resourceTimeout: TimeInterval = 86_400,
                                      waitsForConnectivity: Bool = true) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = resourceTimeout
        config.httpAdditionalHeaders = ["User-Agent": defaultUserAgent]
        config.waitsForConnectivity = waitsForConnectivity
        // Re-validate every redirect target against the SSRF guard so a public
        // URL can't 30x into a private/loopback/metadata host. The delegate is
        // retained by the session for its lifetime.
        return URLSession(configuration: config, delegate: redirectGuard, delegateQueue: nil)
    }

    /// Fetch with bounded retry for the research web tools.
    ///
    /// Retries transient `URLError`s (timeout, connection lost/reset, host
    /// unreachable, DNS) and retryable HTTP statuses (408/425/429/500/502/503/504),
    /// honoring `Retry-After` when present. A single transient blip or a 429 no
    /// longer permanently fails a source. Non-retryable responses (incl. 4xx
    /// other than 408/425/429) return on the first attempt so real errors surface
    /// fast. Cancellation is never retried.
    public static func dataWithRetry(for request: URLRequest,
                                     session: URLSession,
                                     maxAttempts: Int = 3,
                                     label: String = "fetch") async throws -> (Data, URLResponse) {
        var attempt = 0
        var lastError: Error?
        while attempt < maxAttempts {
            attempt += 1
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse,
                   Self.retryableStatuses.contains(http.statusCode),
                   attempt < maxAttempts {
                    let delay = Self.retryDelay(attempt: attempt, response: http)
                    Log.net.warning("\(label, privacy: .public) HTTP \(http.statusCode) attempt \(attempt); retrying in \(delay)s")
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
                return (data, response)
            } catch let error as URLError where Self.isTransient(error) && attempt < maxAttempts {
                lastError = error
                let delay = Self.retryDelay(attempt: attempt, response: nil)
                Log.net.warning("\(label, privacy: .public) transient \(error.code.rawValue) attempt \(attempt); retrying in \(delay)s")
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        // Exhausted retries on a transient error — surface it.
        if let lastError { throw lastError }
        // Should be unreachable (the loop returns on the final attempt), but
        // keep the type checker honest.
        return try await session.data(for: request)
    }

    static let retryableStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504]

    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private static func retryDelay(attempt: Int, response: HTTPURLResponse?) -> Double {
        if let retryAfter = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(retryAfter) {
            return min(seconds, 10)
        }
        // Exponential backoff with a small jitter, capped.
        let base = min(pow(2.0, Double(attempt - 1)) * 0.5, 6.0)
        return base + Double(attempt) * 0.1
    }
}
