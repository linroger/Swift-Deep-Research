import Foundation

/// Drives the multi-round research loop:
///   plan → workers → draft → reflect →
///     if (gaps or unsupported claims) and rounds < max → workers (gaps) → re-synthesize → reflect
///     else → done
///
/// Each round emits events into the shared stream so the UI shows progress
/// across iterations rather than going dark between rounds.
public struct IterationController: Sendable, Codable, Equatable {
    public var maxRounds: Int
    public var reflectAfterFirstRound: Bool

    public init(maxRounds: Int = 3, reflectAfterFirstRound: Bool = true) {
        self.maxRounds = max(1, maxRounds)
        self.reflectAfterFirstRound = reflectAfterFirstRound
    }

    public static let fast = IterationController(maxRounds: 1, reflectAfterFirstRound: false)
    public static let standard = IterationController(maxRounds: 3, reflectAfterFirstRound: true)
    public static let thorough = IterationController(maxRounds: 6, reflectAfterFirstRound: true)
}
