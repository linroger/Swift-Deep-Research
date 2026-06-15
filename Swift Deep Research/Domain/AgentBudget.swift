import Foundation

/// Hard caps the engine enforces per research run.
///
/// Anthropic's multi-agent research system found that a 4× orchestration premium
/// (~15× tokens vs. single-shot) yielded 90% better outputs. We surface explicit
/// caps so the user can choose their cost/quality tradeoff in Settings.
public struct AgentBudget: Sendable, Codable, Equatable {
    public var maxTokens: Int
    public var maxWorkers: Int
    public var maxSourcesPerWorker: Int
    public var maxToolCallsPerWorker: Int
    public var maxWallClock: Duration

    public init(maxTokens: Int,
                maxWorkers: Int,
                maxSourcesPerWorker: Int,
                maxToolCallsPerWorker: Int,
                maxWallClock: Duration) {
        self.maxTokens = maxTokens
        self.maxWorkers = maxWorkers
        self.maxSourcesPerWorker = maxSourcesPerWorker
        self.maxToolCallsPerWorker = maxToolCallsPerWorker
        self.maxWallClock = maxWallClock
    }

    // Wall-clock caps target local-Ollama latency: gpt-oss synthesis with
    // multi-round reflection consistently runs 4-8 minutes on M-series Macs,
    // so the previous 60/180/360s caps killed runs mid-synthesis. New caps
    // give the engine enough wall time to actually finish, while still
    // bounding pathological hangs.
    public static let fast = AgentBudget(
        maxTokens: 60_000,
        maxWorkers: 2,
        maxSourcesPerWorker: 4,
        maxToolCallsPerWorker: 6,
        maxWallClock: .seconds(180)
    )

    public static let standard = AgentBudget(
        maxTokens: 300_000,
        maxWorkers: 4,
        maxSourcesPerWorker: 6,
        maxToolCallsPerWorker: 20,
        maxWallClock: .seconds(900)
    )

    public static let thorough = AgentBudget(
        maxTokens: 800_000,
        maxWorkers: 6,
        maxSourcesPerWorker: 12,
        maxToolCallsPerWorker: 36,
        maxWallClock: .seconds(1_800)
    )
}

/// Thread-safe token meter shared across orchestrator and workers.
public actor BudgetMeter {
    private(set) var tokensUsed: Int = 0
    private(set) var toolCallsByWorker: [WorkerID: Int] = [:]
    private(set) var sourcesByWorker: [WorkerID: Int] = [:]
    private let budget: AgentBudget
    private let startedAt: ContinuousClock.Instant = ContinuousClock().now

    public init(budget: AgentBudget) { self.budget = budget }

    public func chargeTokens(_ n: Int) throws {
        tokensUsed += n
        if tokensUsed > budget.maxTokens {
            throw EngineFailure(kind: .budgetExceeded,
                                message: "Token cap \(budget.maxTokens) exceeded (used \(tokensUsed)).")
        }
    }

    public func registerToolCall(by worker: WorkerID) throws {
        let n = (toolCallsByWorker[worker] ?? 0) + 1
        toolCallsByWorker[worker] = n
        if n > budget.maxToolCallsPerWorker {
            throw EngineFailure(kind: .budgetExceeded,
                                message: "Worker \(worker.raw) exceeded \(budget.maxToolCallsPerWorker) tool calls.",
                                workerID: worker)
        }
    }

    public func registerSource(for worker: WorkerID) -> Bool {
        let n = (sourcesByWorker[worker] ?? 0) + 1
        sourcesByWorker[worker] = n
        return n <= budget.maxSourcesPerWorker
    }

    /// Give back a source slot reserved by `registerSource` when the fetch it
    /// was reserved for failed. Without this, a worker that hits transient fetch
    /// failures "spends" its whole source budget on nothing and then reports
    /// "Source cap reached" despite having read zero sources.
    public func releaseSource(for worker: WorkerID) {
        if let n = sourcesByWorker[worker], n > 0 {
            sourcesByWorker[worker] = n - 1
        }
    }

    public func checkWallClock() throws {
        let elapsed = ContinuousClock().now - startedAt
        if elapsed > budget.maxWallClock {
            throw EngineFailure(kind: .budgetExceeded,
                                message: "Wall-clock cap \(budget.maxWallClock) exceeded.")
        }
    }

    public var snapshot: Snapshot {
        Snapshot(tokensUsed: tokensUsed,
                 maxTokens: budget.maxTokens,
                 elapsed: ContinuousClock().now - startedAt)
    }

    /// The per-worker tool-call ceiling for this run's budget mode. Exposed so a
    /// worker's LLM-hop cap can track the tool budget rather than being a fixed
    /// constant that may bind BEFORE the tool budget is spent — thorough allows
    /// 36 tool calls, so a hardcoded 32-hop cap cut workers off early
    /// (engine-hops-cap-decoupled-from-budget).
    public var toolCallBudget: Int { budget.maxToolCallsPerWorker }

    /// Wall-clock budget still available, clamped at zero. Used to derive a
    /// per-call timeout so a single LLM/tool call can't outlive the whole run.
    public var remainingWallClock: Duration {
        let remaining = budget.maxWallClock - (ContinuousClock().now - startedAt)
        return remaining > .zero ? remaining : .zero
    }

    public struct Snapshot: Sendable {
        public let tokensUsed: Int
        public let maxTokens: Int
        public let elapsed: Duration
        public var tokenFraction: Double { Double(tokensUsed) / Double(max(maxTokens, 1)) }
    }
}
