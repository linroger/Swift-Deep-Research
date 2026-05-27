import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Foundation Models — on-device ~3B parameter LLM, free.
/// 4096-token context. Suited for orchestration/structured-plan emission,
/// not heavy synthesis (route those to cloud).
public struct FoundationModelsClient: LLMClient {
    public let identity: LLMClientIdentity

    public init() {
        self.identity = LLMClientIdentity(
            providerID: "foundationmodels",
            displayName: "Apple Foundation Models (on-device)",
            defaultModel: "apple-fm-base",
            availableModels: ["apple-fm-base"],
            supportsToolCalling: false,
            contextWindow: 4_096
        )
    }

    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    #if canImport(FoundationModels)
                    if #available(macOS 26.0, *) {
                        try await Self.runStream(request: request, continuation: continuation)
                        return
                    }
                    #endif
                    throw EngineFailure(
                        kind: .configurationMissing,
                        message: "Foundation Models requires macOS 26 with Apple Intelligence enabled."
                    )
                } catch {
                    continuation.yield(.finished(reason: .error))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func runStream(request: LLMRequest,
                                  continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation) async throws {
        guard SystemLanguageModel.default.isAvailable else {
            throw EngineFailure(kind: .configurationMissing,
                                message: "Foundation Models not enabled on this device.")
        }
        let systemPrompt = request.messages.first(where: { $0.role == .system })?.plainText
        let session = LanguageModelSession(instructions: systemPrompt ?? "")
        let userText = request.messages
            .filter { $0.role != .system }
            .map { "\($0.role.rawValue): \($0.plainText)" }
            .joined(separator: "\n")

        let opts = GenerationOptions(temperature: request.temperature,
                                     maximumResponseTokens: request.maxTokens ?? 1024)
        let stream = session.streamResponse(to: userText, options: opts)
        var lastSeen = ""
        for try await partial in stream {
            // Partial responses arrive as the full text-so-far; emit only the delta.
            let snapshot = String(describing: partial)
            if snapshot.hasPrefix(lastSeen) {
                let delta = String(snapshot.dropFirst(lastSeen.count))
                if !delta.isEmpty { continuation.yield(.text(delta)) }
                lastSeen = snapshot
            } else {
                continuation.yield(.text(snapshot))
                lastSeen = snapshot
            }
        }
        continuation.yield(.usage(promptTokens: 0, completionTokens: lastSeen.count / 4))
        continuation.yield(.finished(reason: .stop))
        continuation.finish()
    }
    #endif
}
