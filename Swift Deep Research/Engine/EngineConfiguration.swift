import Foundation

/// User-facing configuration for one research run.
///
/// `Codable`/`Equatable` so the whole configuration survives app relaunches
/// (persisted by `AppEnvironment`) — essential for custom endpoints, which are
/// useless if they reset every launch.
public struct EngineConfiguration: Sendable, Codable, Equatable {
    public var orchestratorProvider: ProviderRegistry.ProviderID
    public var orchestratorModel: String?
    public var workerProvider: ProviderRegistry.ProviderID
    public var workerModel: String?
    public var synthesisProvider: ProviderRegistry.ProviderID
    public var synthesisModel: String?
    public var budget: AgentBudget
    public var iteration: IterationController
    public var ollamaHost: URL
    /// Local OpenAI-compatible server for the LM Studio provider.
    public var lmStudioHost: URL
    /// Base URL for the user-defined "Custom endpoint" provider. Resolved to
    /// `/v1/chat/completions` at call time. `nil` until the user sets one.
    public var customEndpointBaseURL: URL?
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
                lmStudioHost: URL = URL(string: "http://localhost:1234")!,
                customEndpointBaseURL: URL? = nil,
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
        self.lmStudioHost = lmStudioHost
        self.customEndpointBaseURL = customEndpointBaseURL
        self.seekdbHost = seekdbHost
        self.useKnowledgeBase = useKnowledgeBase
        self.systemPromptAddendum = systemPromptAddendum
    }

    // Tolerant decoding: new fields added in later versions fall back to
    // sensible defaults when an older persisted blob is read.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orchestratorProvider = try c.decode(ProviderRegistry.ProviderID.self, forKey: .orchestratorProvider)
        orchestratorModel = try c.decodeIfPresent(String.self, forKey: .orchestratorModel)
        workerProvider = try c.decode(ProviderRegistry.ProviderID.self, forKey: .workerProvider)
        workerModel = try c.decodeIfPresent(String.self, forKey: .workerModel)
        synthesisProvider = try c.decode(ProviderRegistry.ProviderID.self, forKey: .synthesisProvider)
        synthesisModel = try c.decodeIfPresent(String.self, forKey: .synthesisModel)
        budget = try c.decode(AgentBudget.self, forKey: .budget)
        iteration = try c.decode(IterationController.self, forKey: .iteration)
        ollamaHost = try c.decodeIfPresent(URL.self, forKey: .ollamaHost)
            ?? URL(string: "http://localhost:11434")!
        lmStudioHost = try c.decodeIfPresent(URL.self, forKey: .lmStudioHost)
            ?? URL(string: "http://localhost:1234")!
        customEndpointBaseURL = try c.decodeIfPresent(URL.self, forKey: .customEndpointBaseURL)
        seekdbHost = try c.decodeIfPresent(URL.self, forKey: .seekdbHost)
            ?? URL(string: "http://127.0.0.1:9100")!
        useKnowledgeBase = try c.decodeIfPresent(Bool.self, forKey: .useKnowledgeBase) ?? false
        systemPromptAddendum = try c.decodeIfPresent(String.self, forKey: .systemPromptAddendum) ?? ""
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
