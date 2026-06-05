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
            // Retry provider HTTP 429 / 5xx; pattern-match on the message.
            if engineFailure.kind == .providerFailure {
                let m = engineFailure.message.lowercased()
                return m.contains("429") || m.contains("503") || m.contains("502") ||
                       m.contains("500") || m.contains("rate limit")
            }
        }
        return false
    }
}
