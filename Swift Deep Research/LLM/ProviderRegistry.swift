import Foundation

/// Factory that constructs `LLMClient` instances from configuration.
/// Knows how to read API keys from `KeychainStore` and which model belongs to which provider.
public struct ProviderRegistry: Sendable {
    public enum ProviderID: String, Sendable, CaseIterable, Codable {
        case anthropic, openai, gemini, ollama, mlx, foundationmodels

        public var displayName: String {
            switch self {
            case .anthropic: "Anthropic Claude"
            case .openai: "OpenAI"
            case .gemini: "Google Gemini"
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
            case .openai: ["gpt-5.5",
                           "gpt-5.5-2026-04-23",
                           "gpt-5.4",
                           "gpt-5.4-mini",
                           "gpt-5.4-nano",
                           "gpt-5",
                           "gpt-4.1"]
            case .gemini: ["gemini-3-pro-preview",
                           "gemini-3-flash-preview",
                           "gemini-2.5-pro",
                           "gemini-2.5-flash",
                           "gemini-2.5-flash-lite",
                           "gemini-2.0-flash"]
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
            default: nil
            }
        }
    }

    public init() {}

    /// Build a client for the given provider/model, reading the relevant key from Keychain.
    public func makeClient(provider: ProviderID,
                          model: String? = nil,
                          ollamaHost: URL = URL(string: "http://localhost:11434")!) async throws -> any LLMClient {
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
