import Foundation

/// OpenAI Chat Completions (GPT-5 / o-series). A thin specialization of
/// `OpenAICompatibleClient` — the OpenAI endpoint is the canonical
/// implementation of the chat-completions wire format that DeepSeek, MiniMax,
/// Kimi, LM Studio, and custom endpoints all share.
///
/// The one OpenAI-specific wrinkle: newer models require
/// `max_completion_tokens` rather than the legacy `max_tokens`, so we select
/// the `.completion` token parameter here.
public struct OpenAIClient: LLMClient {
    public static let models = [
        "gpt-5.5",
        "gpt-5.5-2026-04-23",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
        "gpt-5",
        "gpt-4.1"
    ]

    private let inner: OpenAICompatibleClient
    public var identity: LLMClientIdentity { inner.identity }

    public init(apiKey: String,
                model: String = "gpt-5.5",
                baseURL: URL = URL(string: "https://api.openai.com")!,
                session: URLSession = HTTPClientCommon.defaultSession(timeout: 300)) {
        self.inner = OpenAICompatibleClient(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            identity: LLMClientIdentity(
                providerID: "openai",
                displayName: "OpenAI — \(model)",
                defaultModel: model,
                availableModels: OpenAIClient.models,
                supportsToolCalling: true,
                contextWindow: 400_000
            ),
            requiresKey: true,
            tokenParameter: .completion,
            session: session
        )
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        inner.stream(request)
    }
}
