import Foundation

/// Factory that constructs `LLMClient` instances from configuration.
/// Knows how to read API keys from `KeychainStore` and which model belongs to which provider.
public struct ProviderRegistry: Sendable {
    public enum ProviderID: String, Sendable, CaseIterable, Codable {
        case anthropic, openai, gemini
        case deepseek, minimax, kimi, qwen
        case lmstudio, custom
        case ollama, mlx, foundationmodels

        public var displayName: String {
            switch self {
            case .anthropic: "Anthropic Claude"
            case .openai: "OpenAI"
            case .gemini: "Google Gemini"
            case .deepseek: "DeepSeek"
            case .minimax: "MiniMax"
            case .kimi: "Moonshot Kimi"
            case .qwen: "Qwen (Alibaba Cloud)"
            case .lmstudio: "LM Studio (local)"
            case .custom: "Custom endpoint"
            case .ollama: "Ollama (local)"
            case .mlx: "MLX (on-device)"
            case .foundationmodels: "Apple Foundation Models"
            }
        }

        public var defaultModel: String {
            switch self {
            case .anthropic: "claude-sonnet-4-20250514"
            case .openai: "gpt-5.5"
            case .gemini: "gemini-3-pro-preview"
            case .deepseek: "deepseek-chat"
            case .minimax: "MiniMax-M2"
            case .kimi: "kimi-k2.6"
            case .qwen: "qwen-max"
            case .lmstudio: "local-model"
            case .custom: "gpt-4o-mini"
            case .ollama: "qwen3:8b"
            case .mlx: "mlx-community/Qwen2.5-7B-Instruct-4bit"
            case .foundationmodels: "apple-fm-base"
            }
        }

        public var availableModels: [String] {
            switch self {
            case .anthropic: ["claude-opus-4-1-20250805",
                              "claude-opus-4-20250514",
                              "claude-sonnet-4-20250514",
                              "claude-3-7-sonnet-20250219",
                              "claude-3-5-haiku-20241022"]
            case .openai: OpenAIClient.models
            case .gemini: ["gemini-3-pro-preview",
                           "gemini-3-flash-preview",
                           "gemini-2.5-pro",
                           "gemini-2.5-flash",
                           "gemini-2.5-flash-lite",
                           "gemini-2.0-flash"]
            case .deepseek: ["deepseek-chat", "deepseek-reasoner"]
            case .minimax: ["MiniMax-M2.1", "MiniMax-M2", "MiniMax-Text-01", "abab6.5s-chat"]
            case .kimi: ["kimi-k2.6",
                         "kimi-k2.5",
                         "kimi-k2-turbo-preview",
                         "kimi-latest",
                         "moonshot-v1-128k",
                         "moonshot-v1-32k",
                         "moonshot-v1-8k"]
            case .qwen: ["qwen-max",
                         "qwen-plus",
                         "qwen-turbo",
                         "qwen3-max",
                         "qwen3-235b-a22b",
                         "qwq-32b",
                         "qwen2.5-72b-instruct",
                         "qwen2.5-32b-instruct"]
            case .lmstudio: []      // discovered live from /v1/models
            case .custom: []        // user-defined
            case .ollama: ["qwen3:8b", "qwen2.5:7b", "deepseek-r1:14b", "mistral-small:24b"]
            case .mlx: ["mlx-community/Qwen2.5-7B-Instruct-4bit",
                        "mlx-community/Qwen2.5-14B-Instruct-4bit",
                        "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit"]
            case .foundationmodels: ["apple-fm-base"]
            }
        }

        public var requiresAPIKey: KeyAccount? {
            switch self {
            case .anthropic: .anthropic
            case .openai: .openAI
            case .gemini: .gemini
            case .deepseek: .deepseek
            case .minimax: .minimax
            case .kimi: .moonshot
            case .qwen: .qwen
            case .custom: .custom
            default: nil      // lmstudio / ollama / mlx / foundationmodels: no key
            }
        }

        /// True for providers whose model id is free-form (typed by the user or
        /// discovered live) rather than chosen from a fixed list.
        public var usesFreeformModel: Bool {
            switch self {
            case .deepseek, .minimax, .kimi, .qwen, .lmstudio, .custom, .ollama: true
            default: false
            }
        }

        /// True for endpoints that expose a live model list we can fetch:
        /// OpenAI-standard `GET /v1/models`, Anthropic/Gemini model APIs, or
        /// Ollama's `/api/tags`. Drives the "Test & fetch models" affordance.
        public var supportsModelDiscovery: Bool {
            switch self {
            case .anthropic, .openai, .gemini,
                 .deepseek, .minimax, .kimi, .qwen,
                 .lmstudio, .custom, .ollama:
                return true
            case .mlx, .foundationmodels:
                return false   // on-device, no remote catalogue
            }
        }
    }

    public init() {}

    /// Build a client for the given provider/model, reading the relevant key from Keychain.
    /// Default Qwen / Alibaba Cloud Model Studio (MaaS) OpenAI-compatible host.
    /// The MaaS gateway exposes OpenAI-compatible routes under `/compatible-mode/v1`
    /// (verified: `/compatible-mode/v1/models` and `/compatible-mode/v1/chat/completions`
    /// authenticate, whereas a bare `/v1/...` 404s). Overridable per-config for a
    /// user's own dedicated deployment.
    public static let defaultQwenBaseURL =
        URL(string: "https://ws-tadf5kfijdfuj988.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1")!

    public func makeClient(provider: ProviderID,
                          model: String? = nil,
                          ollamaHost: URL = URL(string: "http://localhost:11434")!,
                          lmStudioHost: URL = URL(string: "http://localhost:1234")!,
                          customBaseURL: URL? = nil,
                          qwenBaseURL: URL? = nil) async throws -> any LLMClient {
        let chosenModel = model ?? provider.defaultModel
        switch provider {
        case .anthropic:
            let key = await KeychainStore.shared.get(.anthropic) ?? ""
            return AnthropicClient(apiKey: key, model: chosenModel)
        case .openai:
            let key = await KeychainStore.shared.get(.openAI) ?? ""
            return OpenAIClient(apiKey: key, model: chosenModel)
        case .gemini:
            let key = await KeychainStore.shared.get(.gemini) ?? ""
            return GeminiClient(apiKey: key, model: chosenModel)
        case .deepseek:
            return try await makeOpenAICompatible(
                provider: provider, model: chosenModel,
                baseURL: URL(string: "https://api.deepseek.com")!,
                key: .deepseek, contextWindow: 128_000)
        case .minimax:
            return try await makeOpenAICompatible(
                provider: provider, model: chosenModel,
                baseURL: URL(string: "https://api.minimax.io")!,
                key: .minimax, contextWindow: 1_000_000)
        case .kimi:
            return try await makeOpenAICompatible(
                provider: provider, model: chosenModel,
                baseURL: URL(string: "https://api.moonshot.ai")!,
                key: .moonshot, contextWindow: 200_000)
        case .qwen:
            // Alibaba Cloud Model Studio (MaaS) — OpenAI-compatible. The MaaS
            // dedicated endpoint exposes /v1/chat/completions and /v1/models.
            return try await makeOpenAICompatible(
                provider: provider, model: chosenModel,
                baseURL: qwenBaseURL ?? Self.defaultQwenBaseURL,
                key: .qwen, contextWindow: 256_000)
        case .lmstudio:
            // Local server — no key required.
            return OpenAICompatibleClient(
                apiKey: "",
                model: chosenModel,
                baseURL: lmStudioHost,
                identity: identity(for: provider, model: chosenModel, contextWindow: 128_000),
                requiresKey: false,
                tokenParameter: .legacy)
        case .custom:
            guard let base = customBaseURL else {
                throw EngineFailure(kind: .configurationMissing,
                                    message: "No custom endpoint URL set. Add one in Settings → Providers.")
            }
            let key = await KeychainStore.shared.get(.custom) ?? ""
            return OpenAICompatibleClient(
                apiKey: key,
                model: chosenModel,
                baseURL: base,
                identity: identity(for: provider, model: chosenModel, contextWindow: 128_000),
                requiresKey: false,      // many self-hosted gateways need no key
                tokenParameter: .legacy)
        case .ollama:
            // Self-heal: if the configured model isn't actually installed
            // locally, pick whatever IS installed. Avoids the "model 'X' not
            // found" 404 when the UI's saved model name lags behind reality.
            let resolved = await Self.resolveOllamaModel(host: ollamaHost,
                                                        requested: chosenModel)
            return OllamaClient(host: ollamaHost, model: resolved)
        case .mlx:
            return MLXClient(modelID: chosenModel)
        case .foundationmodels:
            return FoundationModelsClient()
        }
    }

    // MARK: - OpenAI-compatible plumbing

    private func makeOpenAICompatible(provider: ProviderID,
                                      model: String,
                                      baseURL: URL,
                                      key: KeyAccount,
                                      contextWindow: Int) async throws -> any LLMClient {
        let apiKey = await KeychainStore.shared.get(key) ?? ""
        return OpenAICompatibleClient(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            identity: identity(for: provider, model: model, contextWindow: contextWindow),
            requiresKey: true,
            tokenParameter: .legacy)
    }

    private func identity(for provider: ProviderID, model: String, contextWindow: Int) -> LLMClientIdentity {
        LLMClientIdentity(
            providerID: provider.rawValue,
            displayName: "\(provider.displayName) — \(model)",
            defaultModel: model,
            availableModels: provider.availableModels,
            supportsToolCalling: true,
            contextWindow: contextWindow)
    }

    /// Compare `requested` against /api/tags. If it's installed, use it as-is.
    /// If not, fall back to the first installed model so the run doesn't fail
    /// with `model 'X' not found`. If Ollama is offline, return the requested
    /// name and let the actual API call surface the connection error.
    private static func resolveOllamaModel(host: URL, requested: String) async -> String {
        guard let installed = try? await OllamaClient.listModels(host: host),
              !installed.isEmpty else {
            return requested
        }
        if installed.contains(requested) { return requested }
        // Prefer base-name match (e.g. "qwen3:8b" matches "qwen3:8b" or
        // "qwen3:8b-instruct") before falling back to first installed.
        let baseName = requested.split(separator: ":").first.map(String.init) ?? requested
        if let match = installed.first(where: { $0.hasPrefix(baseName) }) {
            return match
        }
        return installed[0]
    }
}
