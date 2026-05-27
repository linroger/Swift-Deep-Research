import Foundation

/// MLX-Swift on-device inference.
///
/// v2.0 ships with the MLX provider as a placeholder that returns a configuration
/// error explaining how to enable it. The mlx-swift / mlx-swift-examples APIs
/// have moved several times across releases (loadContainer / perform / generate
/// signatures changed in 0.21 → 0.23 → 0.31), so wiring the full path is tracked
/// as a v2.1 task. Until then, users who want local inference should use Ollama,
/// which already supports the same MLX-quantized models via `ollama pull`.
public struct MLXClient: LLMClient {
    public let identity: LLMClientIdentity
    private let modelID: String

    public init(modelID: String = "mlx-community/Qwen2.5-7B-Instruct-4bit") {
        self.modelID = modelID
        self.identity = LLMClientIdentity(
            providerID: "mlx",
            displayName: "MLX — \(Self.shortName(modelID)) (stub)",
            defaultModel: modelID,
            availableModels: [
                "mlx-community/Qwen2.5-7B-Instruct-4bit",
                "mlx-community/Qwen2.5-14B-Instruct-4bit",
                "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit",
                "mlx-community/Mistral-Small-24B-Instruct-2501-4bit"
            ],
            supportsToolCalling: false,
            contextWindow: 32_000
        )
    }

    private static func shortName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.finished(reason: .error))
            continuation.finish(throwing: EngineFailure(
                kind: .configurationMissing,
                message: "MLX provider is not yet wired in v2.0. Use Ollama instead to run \(modelID) locally."
            ))
        }
    }
}
