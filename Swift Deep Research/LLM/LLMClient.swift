import Foundation

/// The single contract every LLM provider speaks.
///
/// `stream(_:)` is the only required method. Convenience non-streaming and
/// structured-output methods build on top so providers only implement once.
public protocol LLMClient: Sendable {
    var identity: LLMClientIdentity { get }

    /// Yields chunks as the model generates. Caller drains the stream; cancellation
    /// of the consuming `Task` cancels the underlying network request.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error>
}

public struct LLMClientIdentity: Sendable, Equatable, Hashable {
    public let providerID: String        // "anthropic" | "openai" | ...
    public let displayName: String
    public let defaultModel: String
    public let availableModels: [String]
    public let supportsToolCalling: Bool
    public let contextWindow: Int

    public init(providerID: String,
                displayName: String,
                defaultModel: String,
                availableModels: [String],
                supportsToolCalling: Bool,
                contextWindow: Int) {
        self.providerID = providerID
        self.displayName = displayName
        self.defaultModel = defaultModel
        self.availableModels = availableModels
        self.supportsToolCalling = supportsToolCalling
        self.contextWindow = contextWindow
    }
}

// MARK: - Convenience defaults

public extension LLMClient {
    /// Drain the stream and return the final assembled text plus any tool calls.
    func complete(_ request: LLMRequest) async throws -> LLMCompletion {
        var text = ""
        var toolCalls: [PartialToolCall] = []
        var currentIndex: [String: Int] = [:]
        var usage: (prompt: Int, completion: Int) = (0, 0)
        var finish: LLMStreamChunk.FinishReason = .stop

        for try await chunk in stream(request) {
            switch chunk {
            case .text(let s):
                text += s
            case .toolCallStart(let id, let name):
                let idx = toolCalls.count
                currentIndex[id] = idx
                toolCalls.append(PartialToolCall(id: id, name: name, argumentsJSON: ""))
            case .toolCallArgumentsDelta(let id, let delta):
                if let idx = currentIndex[id] {
                    toolCalls[idx].argumentsJSON += delta
                }
            case .toolCallEnd:
                continue
            case .usage(let p, let c):
                usage = (p, c)
            case .finished(let reason):
                finish = reason
            }
        }
        return LLMCompletion(
            text: text,
            toolCalls: toolCalls,
            promptTokens: usage.prompt,
            completionTokens: usage.completion,
            finishReason: finish
        )
    }
}

public struct PartialToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public var argumentsJSON: String
    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id; self.name = name; self.argumentsJSON = argumentsJSON
    }
}

public struct LLMCompletion: Sendable {
    public let text: String
    public let toolCalls: [PartialToolCall]
    public let promptTokens: Int
    public let completionTokens: Int
    public let finishReason: LLMStreamChunk.FinishReason

    public var totalTokens: Int { promptTokens + completionTokens }
}
