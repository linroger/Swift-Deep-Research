import Foundation

/// Which research methodology drives a deep-research run.
///
/// - `native`: the original multi-agent engine — plan once, fan out parallel
///   workers, reflect, re-synthesize.
/// - `deerflow`: DeerFlow's plan-and-execute loop — background investigation
///   (web + private knowledge base), a structured plan with explicit steps,
///   sequential step execution with observation threading, and re-planning
///   until the planner judges the context sufficient.
public enum ResearchFlow: String, Sendable, Codable, CaseIterable, Identifiable {
    case native, deerflow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .native: "Native multi-agent"
        case .deerflow: "DeerFlow plan-and-execute"
        }
    }

    public var blurb: String {
        switch self {
        case .native:
            "Plans once, fans out parallel workers, then reflects and deepens across rounds."
        case .deerflow:
            "Investigates first (web + knowledge base), plans explicit steps, executes them sequentially with shared observations, and re-plans until the context is sufficient."
        }
    }
}

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
    /// Base URL for the Qwen / Alibaba Cloud Model Studio (MaaS) provider.
    /// Defaults to the bundled dedicated endpoint; editable in Settings.
    public var qwenBaseURL: URL
    public var seekdbHost: URL
    /// When true the engine exposes the `knowledge_base` tool to workers so
    /// they can search the user's uploaded documents alongside the web.
    public var useKnowledgeBase: Bool
    /// Free-form user instructions injected into the orchestrator and worker
    /// system prompts. Empty by default.
    public var systemPromptAddendum: String
    /// Which research methodology drives the run (native multi-agent vs.
    /// DeerFlow plan-and-execute). Defaults to `.native`.
    public var researchFlow: ResearchFlow

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
                qwenBaseURL: URL = ProviderRegistry.defaultQwenBaseURL,
                seekdbHost: URL = URL(string: "http://127.0.0.1:9100")!,
                useKnowledgeBase: Bool = false,
                systemPromptAddendum: String = "",
                researchFlow: ResearchFlow = .native) {
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
        self.qwenBaseURL = qwenBaseURL
        self.seekdbHost = seekdbHost
        self.useKnowledgeBase = useKnowledgeBase
        self.systemPromptAddendum = systemPromptAddendum
        self.researchFlow = researchFlow
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
        qwenBaseURL = try c.decodeIfPresent(URL.self, forKey: .qwenBaseURL)
            ?? ProviderRegistry.defaultQwenBaseURL
        seekdbHost = try c.decodeIfPresent(URL.self, forKey: .seekdbHost)
            ?? URL(string: "http://127.0.0.1:9100")!
        useKnowledgeBase = try c.decodeIfPresent(Bool.self, forKey: .useKnowledgeBase) ?? false
        systemPromptAddendum = try c.decodeIfPresent(String.self, forKey: .systemPromptAddendum) ?? ""
        researchFlow = try c.decodeIfPresent(ResearchFlow.self, forKey: .researchFlow) ?? .native
    }

    /// A reasonable starting configuration that is **runnable out of the box**.
    ///
    /// If Apple Foundation Models is available, route ALL three roles to it so a
    /// fresh user with Apple Intelligence gets a working run with zero API keys
    /// and zero configuration. (FM can't tool-call, so research is the model's
    /// built-in knowledge until the user — or `autoConfigureLocalProviderIfNeeded`
    /// — points the worker at a tool-capable provider; the config banner surfaces
    /// this.) Only when no on-device model exists do we default to Anthropic, and
    /// the missing-key banner then guides the user to add a key or start a local
    /// model. Never ship a default whose worker/synthesis require a key the user
    /// has not provided (E3-llm-1).
    public static func suggestedDefault() -> EngineConfiguration {
        if FoundationModelsClient.isAvailable {
            return EngineConfiguration(
                orchestratorProvider: .foundationmodels,
                orchestratorModel: nil,
                workerProvider: .foundationmodels,
                workerModel: nil,
                synthesisProvider: .foundationmodels,
                synthesisModel: nil,
                budget: .standard,
                iteration: .standard
            )
        }
        return EngineConfiguration(
            orchestratorProvider: .anthropic,
            orchestratorModel: "claude-3-5-haiku-20241022",
            workerProvider: .anthropic,
            workerModel: "claude-sonnet-4-20250514",
            synthesisProvider: .anthropic,
            synthesisModel: "claude-sonnet-4-20250514",
            budget: .standard,
            iteration: .standard
        )
    }
}
