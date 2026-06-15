import Foundation

/// Thrown when an operation wrapped in `withTimeout` exceeds its deadline.
public struct TimedOutError: Error, LocalizedError {
    public let duration: Duration
    public var errorDescription: String? {
        "Operation timed out after \(duration.components.seconds)s"
    }
}

/// Run `operation`, but fail with `TimedOutError` if it doesn't finish within
/// `duration`. Used to bound a single LLM call or tool invocation so one hung
/// provider stream / stuck socket can't outlive the run's wall-clock budget —
/// `BudgetMeter.checkWallClock()` only fires at loop boundaries, so without this
/// a single in-flight call is effectively unbounded.
///
/// On timeout (or any throw) the loser task is cancelled via `cancelAll()`, which
/// propagates cooperative cancellation into `URLSession` streams. A non-positive
/// `duration` fails fast — the budget is already spent.
public func withTimeout<T: Sendable>(_ duration: Duration,
                                     operation: @escaping @Sendable () async throws -> T) async throws -> T {
    guard duration > .zero else { throw TimedOutError(duration: .zero) }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimedOutError(duration: duration)
        }
        defer { group.cancelAll() }
        // First task to finish wins; the other is cancelled by the defer.
        guard let result = try await group.next() else {
            throw TimedOutError(duration: duration)
        }
        return result
    }
}
