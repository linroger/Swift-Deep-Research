import Foundation

/// Exponential-backoff retry for transient network/provider failures.
///
/// Retries only on classifiable transient errors (HTTP 429, 5xx, timeouts,
/// connection lost). Hard errors (auth, malformed request) fail fast so the
/// user sees the real problem instead of waiting through three retries.
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    public var jitter: Double

    public init(maxAttempts: Int = 3,
                baseDelay: Duration = .milliseconds(500),
                maxDelay: Duration = .seconds(8),
                jitter: Double = 0.3) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    public static let networkDefault = RetryPolicy()
    public static let aggressive = RetryPolicy(maxAttempts: 5,
                                              baseDelay: .milliseconds(300),
                                              maxDelay: .seconds(12))

    public func run<T>(_ operation: @Sendable () async throws -> T,
                       label: String = "op") async throws -> T {
        var attempt = 0
        var lastError: Error?
        while attempt < maxAttempts {
            attempt += 1
            do {
                return try await operation()
            } catch let error where Self.isTransient(error) {
                lastError = error
                if attempt >= maxAttempts { break }
                let delay = backoff(attempt: attempt)
                Log.net.warning("\(label, privacy: .public) attempt \(attempt) failed transiently: \(error.localizedDescription, privacy: .public). Retrying in \(String(describing: delay), privacy: .public).")
                try? await Task.sleep(for: delay)
            } catch {
                throw error
            }
        }
        throw lastError ?? EngineFailure(kind: .providerFailure,
                                         message: "All \(maxAttempts) attempts of \(label) failed.")
    }

    private func backoff(attempt: Int) -> Duration {
        let exponent = pow(2.0, Double(attempt - 1))
        let baseSeconds = Double(baseDelay.components.seconds) +
                         Double(baseDelay.components.attoseconds) / 1e18
        let maxSeconds = Double(maxDelay.components.seconds) +
                        Double(maxDelay.components.attoseconds) / 1e18
        let raw = min(baseSeconds * exponent, maxSeconds)
        let jitterFactor = 1.0 + Double.random(in: -jitter...jitter)
        return .seconds(raw * jitterFactor)
    }

    /// Classify common errors. Anything we can't recognize is treated as
    /// non-transient — better to surface unknown errors than to retry forever.
    public static func isTransient(_ error: Error) -> Bool {
        // A cancelled run must never be retried — it should tear down promptly.
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return false }
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
                 .secureConnectionFailed:
                return true
            default: return false
            }
        }
        if let engineFailure = error as? EngineFailure {
            // Only provider HTTP failures are eligible for retry. Configuration,
            // tool, planning, synthesis, budget, and cancelled failures are fatal.
            if engineFailure.kind == .providerFailure {
                return isTransientProviderMessage(engineFailure.message)
            }
        }
        return false
    }

    /// Classify a provider failure message as transient (retryable) or not.
    ///
    /// `EngineFailure` carries no structured status code (see EXECPLAN2
    /// `retry-enginefailure-string-match-8`), so we fall back to the message.
    /// The earlier implementation used bare-digit `contains("500")` checks,
    /// which misclassified bodies/paths/token-counts that merely *contain*
    /// those digits (e.g. `/v500`, a token count `50000`, or a quoted 200-OK
    /// body mentioning `502`) and missed worded rate limits ("Too Many
    /// Requests") that lack the literal digits. We instead match the HTTP
    /// status only when it appears as a standalone token anchored to an HTTP
    /// status context, plus recognize the canonical worded reason phrases.
    private static func isTransientProviderMessage(_ message: String) -> Bool {
        let lower = message.lowercased()

        // Worded transient reasons that providers surface with or without a
        // numeric code. These are unambiguous phrases, not bare digits.
        let transientPhrases = [
            "rate limit", "too many requests", "service unavailable",
            "bad gateway", "gateway timeout", "internal server error",
            "server overloaded", "overloaded", "temporarily unavailable"
        ]
        if transientPhrases.contains(where: { lower.contains($0) }) {
            return true
        }

        // Numeric HTTP status: match 429 and 5xx only when the code is a
        // standalone token (word boundaries) AND sits next to HTTP-status
        // context ("http", "status", "code", or "error" nearby). Anchoring on
        // context prevents a stray "500" inside a URL or token count from
        // triggering a retry. A leading "status" keyword may also precede it.
        // Examples matched: "Anthropic HTTP 429", "status code 503",
        //                   "HTTP error 502", "503 Service ...".
        let statusPattern =
            #"(?:\b(?:http|status|code|error)\b[^0-9]{0,12}(429|5\d{2})\b)"#
            + #"|(?:\b(429|5\d{2})\b[^0-9]{0,12}\b(?:error|status)\b)"#
        if let regex = try? Regex(statusPattern),
           lower.firstMatch(of: regex) != nil {
            return true
        }
        return false
    }
}
