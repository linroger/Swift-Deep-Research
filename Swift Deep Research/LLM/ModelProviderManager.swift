import Foundation
import Observation

// MARK: - ModelRole

/// Every place in the app that consumes an LLM, unified under one vocabulary.
/// The first three run in-process through `ProviderRegistry`; `forecast` runs
/// on the MiroFish backend, which this manager configures over HTTP / `.env`.
public enum ModelRole: String, Sendable, Codable, CaseIterable, Identifiable {
    case orchestrator, worker, synthesis, forecast

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .orchestrator: "Orchestrator"
        case .worker: "Workers"
        case .synthesis: "Synthesizer"
        case .forecast: "Forecast (MiroFish)"
        }
    }

    public var subtitle: String {
        switch self {
        case .orchestrator: "Decomposes the user's query into sub-tasks."
        case .worker: "Run sub-tasks in parallel with tool calling."
        case .synthesis: "Writes the final markdown answer with citations."
        case .forecast: "Drives the MiroFish backend: DeerFlow research, ontology, simulation agents, and the report."
        }
    }
}

public extension ProviderRegistry {
    /// Unified in-process client factory: both research flows (native and
    /// DeerFlow) build every LLM through this single entry point so role →
    /// provider/model/endpoint resolution lives in exactly one place.
    func makeClient(role: ModelRole, config: EngineConfiguration) async throws -> any LLMClient {
        let provider: ProviderID
        let model: String?
        switch role {
        case .orchestrator:
            provider = config.orchestratorProvider; model = config.orchestratorModel
        case .worker:
            provider = config.workerProvider; model = config.workerModel
        case .synthesis:
            provider = config.synthesisProvider; model = config.synthesisModel
        case .forecast:
            throw EngineFailure(kind: .configurationMissing,
                                message: "The forecast model runs on the MiroFish backend, not in-process.")
        }
        return try await makeClient(provider: provider,
                                    model: model,
                                    ollamaHost: config.ollamaHost,
                                    lmStudioHost: config.lmStudioHost,
                                    customBaseURL: config.customEndpointBaseURL,
                                    qwenBaseURL: config.qwenBaseURL)
    }
}

// MARK: - ModelProviderManager

/// Single source of truth for "which model powers which feature".
///
/// The three research roles keep living in `EngineConfiguration` (persisted by
/// `AppEnvironment`); this manager adds the fourth role — the forecast model —
/// and the bridge that makes the selection real on the MiroFish backend:
///
/// - `pushForecastProvider(client:config:)` switches the backend at runtime via
///   `POST /api/settings/llm` (applies to newly started pipelines), and
/// - `envSeed(config:)` produces the `LLM_*` variables MiroFish reads from its
///   `.env` so a cold-started backend boots straight onto the chosen provider.
///
/// Providers without a native MiroFish integration (Anthropic, Gemini, Ollama,
/// LM Studio, custom) are bridged through the backend's generic OpenAI-compatible
/// provider using each vendor's OpenAI-compatible endpoint. On-device providers
/// (MLX, Apple Foundation Models) can't drive an external backend and are
/// excluded from the eligible list.
@MainActor
@Observable
public final class ModelProviderManager {
    public struct Assignment: Codable, Equatable, Sendable {
        public var provider: ProviderRegistry.ProviderID
        public var model: String?

        public init(provider: ProviderRegistry.ProviderID, model: String? = nil) {
            self.provider = provider
            self.model = model
        }
    }

    public enum PushState: Equatable, Sendable {
        case idle, pushing
        case ok(String)
        case failed(String)
    }

    /// The model that powers forecasts. Persisted; survives relaunch.
    public var forecastAssignment: Assignment
    /// Result of the most recent backend push, surfaced in Settings.
    public var forecastPushState: PushState = .idle

    private static let defaultsKey = "modelProviders.forecast.v1"

    /// Providers that can drive the MiroFish backend (everything that speaks an
    /// HTTP API — on-device engines can't be reached from a separate process).
    public static let forecastEligible: [ProviderRegistry.ProviderID] =
        ProviderRegistry.ProviderID.allCases.filter { $0 != .mlx && $0 != .foundationmodels }

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(Assignment.self, from: data),
           Self.forecastEligible.contains(saved.provider) {
            forecastAssignment = saved
        } else {
            forecastAssignment = Assignment(provider: .minimax)
        }
    }

    public func save() {
        if let data = try? JSONEncoder().encode(forecastAssignment) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: MiroFish bridging

    /// What `POST /api/settings/llm` needs for the current forecast assignment.
    public struct MiroFishPayload: Sendable, Equatable {
        public let provider: String
        public let apiKey: String?
        public let baseURL: String?
        public let model: String?
        /// MiroFish's internal research-model id for `.env` seeding
        /// (`DEERFLOW_MODEL`); mirrors `PROVIDER_META[provider].deerflow_model`.
        public let deerflowModel: String
        /// Provider-specific key mirror the DeerFlow subprocess reads
        /// (e.g. `DEEPSEEK_API_KEY`), when the backend defines one.
        public let keyEnvName: String?
    }

    /// Map the app-side provider onto MiroFish's provider vocabulary, reading
    /// the API key from the Keychain. Returns nil for on-device providers.
    public func mirofishPayload(config: EngineConfiguration) async -> MiroFishPayload? {
        let assignment = forecastAssignment
        let model = assignment.model ?? assignment.provider.defaultModel

        func key(_ account: KeyAccount) async -> String? {
            let k = (await KeychainStore.shared.get(account) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return k.isEmpty ? nil : k
        }

        switch assignment.provider {
        case .openai:
            return MiroFishPayload(provider: "openai", apiKey: await key(.openAI),
                                   baseURL: "https://api.openai.com/v1", model: model,
                                   deerflowModel: "claude", keyEnvName: nil)
        case .anthropic:
            // Anthropic exposes an OpenAI-compatible surface at /v1; MiroFish's
            // generic "openai" provider drives it directly.
            return MiroFishPayload(provider: "openai", apiKey: await key(.anthropic),
                                   baseURL: "https://api.anthropic.com/v1", model: model,
                                   deerflowModel: "claude", keyEnvName: nil)
        case .gemini:
            return MiroFishPayload(provider: "openai", apiKey: await key(.gemini),
                                   baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                                   model: model, deerflowModel: "claude", keyEnvName: nil)
        case .deepseek:
            return MiroFishPayload(provider: "deepseek", apiKey: await key(.deepseek),
                                   baseURL: nil, model: model,
                                   deerflowModel: "deepseek", keyEnvName: "DEEPSEEK_API_KEY")
        case .minimax:
            return MiroFishPayload(provider: "minimax", apiKey: await key(.minimax),
                                   baseURL: nil, model: model,
                                   deerflowModel: "minimax", keyEnvName: "MINIMAX_API_KEY")
        case .kimi:
            return MiroFishPayload(provider: "kimi", apiKey: await key(.moonshot),
                                   baseURL: nil, model: model,
                                   deerflowModel: "kimi", keyEnvName: "KIMI_API_KEY")
        case .qwen:
            return MiroFishPayload(provider: "qwen", apiKey: await key(.qwen),
                                   baseURL: config.qwenBaseURL.absoluteString, model: model,
                                   deerflowModel: "qwen", keyEnvName: "DASHSCOPE_API_KEY")
        case .lmstudio:
            return MiroFishPayload(provider: "openai", apiKey: "lm-studio",
                                   baseURL: Self.openAIBase(config.lmStudioHost), model: model,
                                   deerflowModel: "claude", keyEnvName: nil)
        case .ollama:
            // Ollama serves an OpenAI-compatible API under /v1.
            return MiroFishPayload(provider: "openai", apiKey: "ollama",
                                   baseURL: Self.openAIBase(config.ollamaHost), model: model,
                                   deerflowModel: "claude", keyEnvName: nil)
        case .custom:
            guard let base = config.customEndpointBaseURL else { return nil }
            return MiroFishPayload(provider: "openai",
                                   apiKey: await key(.custom) ?? "none",
                                   baseURL: Self.openAIBase(base), model: model,
                                   deerflowModel: "claude", keyEnvName: nil)
        case .mlx, .foundationmodels:
            return nil
        }
    }

    /// Push the forecast assignment to a live backend. Safe to call repeatedly —
    /// MiroFish applies it to newly started pipelines only.
    public func pushForecastProvider(client: MiroFishClient, config: EngineConfiguration) async {
        forecastPushState = .pushing
        guard let payload = await mirofishPayload(config: config) else {
            forecastPushState = .failed("\(forecastAssignment.provider.displayName) runs on-device and can't drive the MiroFish backend. Pick a cloud or local-server provider for forecasts.")
            return
        }
        if payload.apiKey == nil, forecastAssignment.provider.requiresAPIKey != nil {
            forecastPushState = .failed("\(forecastAssignment.provider.displayName) needs an API key — add one under Settings → API keys.")
            return
        }
        do {
            let info = try await client.setProvider(payload.provider,
                                                    apiKey: payload.apiKey,
                                                    baseURL: payload.baseURL,
                                                    model: payload.model)
            let modelLabel = info.model_name ?? payload.model ?? "default model"
            forecastPushState = .ok("Backend now uses \(forecastAssignment.provider.displayName) (\(modelLabel)). Applies to new forecasts.")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            forecastPushState = .failed(message)
        }
    }

    /// `LLM_*` variables for MiroFish's `.env`, so a cold-started backend boots
    /// straight onto the chosen provider even before the first API push.
    public func envSeed(config: EngineConfiguration) async -> [String: String] {
        guard let payload = await mirofishPayload(config: config) else { return [:] }
        var env: [String: String] = [
            "LLM_PROVIDER": payload.provider,
            "DEERFLOW_MODEL": payload.deerflowModel
        ]
        if let base = payload.baseURL { env["LLM_BASE_URL"] = base }
        if let model = payload.model { env["LLM_MODEL_NAME"] = model }
        if let key = payload.apiKey {
            env["LLM_API_KEY"] = key
            if let mirror = payload.keyEnvName { env[mirror] = key }
        }
        return env
    }

    /// Append "/v1" to a host URL unless it already ends with it — the OpenAI
    /// wire format MiroFish's generic provider expects.
    private static func openAIBase(_ host: URL) -> String {
        let s = host.absoluteString
        let trimmed = s.hasSuffix("/") ? String(s.dropLast()) : s
        return trimmed.hasSuffix("/v1") ? trimmed : trimmed + "/v1"
    }
}
