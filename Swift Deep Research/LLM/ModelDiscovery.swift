import Foundation

/// Fetches a provider's live model catalogue from its API.
///
/// This doubles as an **API-key test**: a successful fetch proves the stored key
/// authenticates against the provider. Settings' "Test & fetch models" button
/// calls `fetchModels` and reports success (with the model list) or the exact
/// failure (missing key, HTTP 401, unreachable host, …).
///
/// Coverage:
///   - Anthropic   `GET /v1/models`              (x-api-key + anthropic-version)
///   - OpenAI      `GET /v1/models`              (Bearer)
///   - Gemini      `GET /v1beta/models?key=`     (query key)
///   - DeepSeek / MiniMax / Kimi / Qwen / LM Studio / Custom
///                 `GET /v1/models`              (OpenAI-compatible, shared client)
///   - Ollama      `GET /api/tags`               (local, no key)
public enum ModelDiscovery {

    public enum DiscoveryError: LocalizedError {
        case missingKey(String)
        case missingEndpoint(String)
        case http(Int, String)
        case unsupported(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .missingKey(let p):
                return "No API key set for \(p). Add one under API keys."
            case .missingEndpoint(let p):
                return "No endpoint URL configured for \(p)."
            case .http(let code, let body):
                let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
                return "HTTP \(code)\(snippet.isEmpty ? "" : " — \(snippet)")"
            case .unsupported(let p):
                return "\(p) has no remote model catalogue."
            case .empty:
                return "The endpoint returned no models."
            }
        }
    }

    /// Resolve the OpenAI-compatible base URL for the providers that share one.
    static func openAICompatibleBase(for provider: ProviderRegistry.ProviderID,
                                     config: EngineConfiguration) -> URL? {
        switch provider {
        case .deepseek: return URL(string: "https://api.deepseek.com")
        case .minimax:  return URL(string: "https://api.minimax.io")
        case .kimi:     return URL(string: "https://api.moonshot.ai")
        case .qwen:     return config.qwenBaseURL
        case .lmstudio: return config.lmStudioHost
        case .custom:   return config.customEndpointBaseURL
        default:        return nil
        }
    }

    /// Fetch the model ids the provider currently advertises. Throws on auth
    /// failure / unreachable host so the caller can surface a precise reason.
    public static func fetchModels(provider: ProviderRegistry.ProviderID,
                                   config: EngineConfiguration) async throws -> [String] {
        switch provider {
        case .anthropic:
            return try await fetchAnthropic()
        case .openai:
            return try await fetchOpenAI()
        case .gemini:
            return try await fetchGemini()
        case .deepseek, .minimax, .kimi, .qwen, .lmstudio, .custom:
            guard let base = openAICompatibleBase(for: provider, config: config) else {
                throw DiscoveryError.missingEndpoint(provider.displayName)
            }
            // Cloud OpenAI-compatible providers require a key; self-hosted
            // custom gateways and local servers may not.
            var key = ""
            if let account = provider.requiresAPIKey {
                key = await KeychainStore.shared.get(account) ?? ""
                if key.isEmpty && provider != .custom {
                    throw DiscoveryError.missingKey(provider.displayName)
                }
            }
            let models = try await OpenAICompatibleClient.listModels(baseURL: base, apiKey: key)
            if models.isEmpty { throw DiscoveryError.empty }
            return models
        case .ollama:
            let models = try await OllamaClient.listModels(host: config.ollamaHost)
            if models.isEmpty { throw DiscoveryError.empty }
            return models
        case .mlx, .foundationmodels:
            throw DiscoveryError.unsupported(provider.displayName)
        }
    }

    // MARK: - Provider-specific endpoints

    private static func fetchAnthropic() async throws -> [String] {
        let key = await KeychainStore.shared.get(.anthropic) ?? ""
        guard !key.isEmpty else { throw DiscoveryError.missingKey("Anthropic") }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await get(req)
        struct Resp: Decodable { struct M: Decodable { let id: String }; let data: [M] }
        let ids = (try? JSONDecoder().decode(Resp.self, from: data))?.data.map(\.id) ?? []
        if ids.isEmpty { throw DiscoveryError.empty }
        return ids.sorted(by: >)   // newest model ids tend to sort high
    }

    private static func fetchOpenAI() async throws -> [String] {
        let key = await KeychainStore.shared.get(.openAI) ?? ""
        guard !key.isEmpty else { throw DiscoveryError.missingKey("OpenAI") }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await get(req)
        struct Resp: Decodable { struct M: Decodable { let id: String }; let data: [M] }
        let all = (try? JSONDecoder().decode(Resp.self, from: data))?.data.map(\.id) ?? []
        // Keep chat-capable models; drop embeddings / audio / image / moderation.
        let drop = ["embedding", "whisper", "tts", "dall-e", "moderation",
                    "audio", "image", "realtime", "transcribe", "search", "computer-use"]
        let chat = all.filter { id in
            let l = id.lowercased()
            return !drop.contains(where: l.contains)
        }
        let result = (chat.isEmpty ? all : chat).sorted()
        if result.isEmpty { throw DiscoveryError.empty }
        return result
    }

    private static func fetchGemini() async throws -> [String] {
        let key = await KeychainStore.shared.get(.gemini) ?? ""
        guard !key.isEmpty else { throw DiscoveryError.missingKey("Gemini") }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200&key=\(key)")!
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await get(req)
        struct Resp: Decodable {
            struct M: Decodable { let name: String; let supportedGenerationMethods: [String]? }
            let models: [M]
        }
        let parsed = (try? JSONDecoder().decode(Resp.self, from: data))?.models ?? []
        let ids = parsed
            .filter { ($0.supportedGenerationMethods ?? []).contains("generateContent") }
            .map { $0.name.replacingOccurrences(of: "models/", with: "") }
        if ids.isEmpty { throw DiscoveryError.empty }
        return ids.sorted(by: >)
    }

    // MARK: - Plumbing

    private static func get(_ request: URLRequest) async throws -> Data {
        let session = HTTPClientCommon.defaultSession(timeout: 15)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DiscoveryError.http(-1, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DiscoveryError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
