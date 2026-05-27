import Foundation

/// User-facing configuration for one research run.
public struct EngineConfiguration: Sendable {
    public var orchestratorProvider: ProviderRegistry.ProviderID
    public var orchestratorModel: String?
    public var workerProvider: ProviderRegistry.ProviderID
    public var workerModel: String?
    public var synthesisProvider: ProviderRegistry.ProviderID
    public var synthesisModel: String?
    public var budget: AgentBudget
    public var iteration: IterationController
    public var ollamaHost: URL
    public var seekdbHost: URL
    /// When true the engine exposes the `knowledge_base` tool to workers so
    /// they can search the user's uploaded documents alongside the web.
    public var useKnowledgeBase: Bool
    /// Free-form user instructions injected into the orchestrator and worker
    /// system prompts. Empty by default.
    public var systemPromptAddendum: String

    public init(orchestratorProvider: ProviderRegistry.ProviderID,
                orchestratorModel: String? = nil,
                workerProvider: ProviderRegistry.ProviderID,
                workerModel: String? = nil,
                synthesisProvider: ProviderRegistry.ProviderID,
                synthesisModel: String? = nil,
                budget: AgentBudget,
                iteration: IterationController = .standard,
                ollamaHost: URL = URL(string: "http://localhost:11434")!,
                seekdbHost: URL = URL(string: "http://127.0.0.1:9100")!,
                useKnowledgeBase: Bool = false,
                systemPromptAddendum: String = "") {
        self.orchestratorProvider = orchestratorProvider
        self.orchestratorModel = orchestratorModel
        self.workerProvider = workerProvider
        self.workerModel = workerModel
        self.synthesisProvider = synthesisProvider
        self.synthesisModel = synthesisModel
        self.budget = budget
        self.iteration = iteration
        self.ollamaHost = ollamaHost
        self.seekdbHost = seekdbHost
        self.useKnowledgeBase = useKnowledgeBase
        self.systemPromptAddendum = systemPromptAddendum
    }

    /// A reasonable starting configuration: orchestrate locally if Foundation Models is available,
    /// otherwise use Anthropic Haiku for the cheap planner. Synthesize with Claude Sonnet.
    public static func suggestedDefault() -> EngineConfiguration {
        let useFM = FoundationModelsClient.isAvailable
        let orchestrator: ProviderRegistry.ProviderID = useFM ? .foundationmodels : .anthropic
        let orchestratorModel: String? = useFM ? nil : "claude-3-5-haiku-20241022"
        return EngineConfiguration(
            orchestratorProvider: orchestrator,
            orchestratorModel: orchestratorModel,
            workerProvider: .anthropic,
            workerModel: "claude-sonnet-4-20250514",
            synthesisProvider: .anthropic,
            synthesisModel: "claude-sonnet-4-20250514",
            budget: .standard,
            iteration: .standard
        )
    }
}
