import Foundation

/// A research tool the orchestrator exposes to worker LLMs.
///
/// Each tool has a JSON-schema description (sent to the LLM as function definition)
/// and an executor that takes the call arguments and produces a `ToolOutcome`.
public protocol ResearchTool: Sendable {
    var spec: LLMToolSpec { get }
    func call(argumentsJSON: String,
              context: ToolContext) async throws -> ToolOutcome
}

/// Per-invocation context: who is calling, where to log, how to emit events.
public struct ToolContext: Sendable {
    public let workerID: WorkerID
    public let session: SessionDescriptor
    public let emit: @Sendable (ResearchEvent) -> Void
    public let charge: @Sendable (Int) async -> Void
    public let budget: BudgetMeter
    public let cache: SourceCache

    public init(workerID: WorkerID,
                session: SessionDescriptor,
                emit: @escaping @Sendable (ResearchEvent) -> Void,
                charge: @escaping @Sendable (Int) async -> Void,
                budget: BudgetMeter,
                cache: SourceCache) {
        self.workerID = workerID
        self.session = session
        self.emit = emit
        self.charge = charge
        self.budget = budget
        self.cache = cache
    }
}
