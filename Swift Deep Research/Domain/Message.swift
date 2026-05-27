import Foundation

/// Unified chat message that every provider speaks.
///
/// Providers internally translate to their wire format (Anthropic Messages API,
/// OpenAI Chat Completions, Gemini contents, Ollama messages, MLX prompts).
/// Tool calls and tool results are first-class so the orchestrator can route
/// them without provider-specific glue.
public struct LLMMessage: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let role: Role
    public let content: [Block]
    public let providerHint: String?

    public init(id: UUID = UUID(), role: Role, content: [Block], providerHint: String? = nil) {
        self.id = id; self.role = role; self.content = content; self.providerHint = providerHint
    }

    public static func system(_ text: String) -> LLMMessage {
        LLMMessage(role: .system, content: [.text(text)])
    }
    public static func user(_ text: String) -> LLMMessage {
        LLMMessage(role: .user, content: [.text(text)])
    }
    public static func assistant(_ text: String) -> LLMMessage {
        LLMMessage(role: .assistant, content: [.text(text)])
    }
    public static func toolResult(callID: String, name: String, output: String) -> LLMMessage {
        LLMMessage(role: .tool, content: [.toolResult(callID: callID, name: name, output: output)])
    }

    public enum Role: String, Sendable, Codable { case system, user, assistant, tool }

    public enum Block: Sendable, Codable, Equatable {
        case text(String)
        case toolCall(id: String, name: String, argumentsJSON: String)
        case toolResult(callID: String, name: String, output: String)
    }

    /// Concatenated text for legacy code paths that don't understand tool blocks.
    public var plainText: String {
        content.compactMap { block in
            switch block {
            case .text(let s): s
            case .toolResult(_, _, let s): s
            case .toolCall: nil
            }
        }.joined(separator: "\n")
    }
}

/// What providers stream back, chunk by chunk.
public enum LLMStreamChunk: Sendable {
    case text(String)
    case toolCallStart(id: String, name: String)
    case toolCallArgumentsDelta(id: String, delta: String)
    case toolCallEnd(id: String)
    case usage(promptTokens: Int, completionTokens: Int)
    case finished(reason: FinishReason)

    public enum FinishReason: String, Sendable {
        case stop, length, toolUse, contentFilter, error, cancelled
    }
}

/// Tool definition exposed to providers for function calling.
public struct LLMToolSpec: Sendable, Codable, Equatable {
    public let name: String
    public let description: String
    public let parametersJSONSchema: String

    public init(name: String, description: String, parametersJSONSchema: String) {
        self.name = name; self.description = description
        self.parametersJSONSchema = parametersJSONSchema
    }
}

/// Provider-agnostic request envelope.
public struct LLMRequest: Sendable {
    public let messages: [LLMMessage]
    public let tools: [LLMToolSpec]
    public let temperature: Double
    public let maxTokens: Int?
    public let stopSequences: [String]
    public let model: String?

    public init(messages: [LLMMessage],
                tools: [LLMToolSpec] = [],
                temperature: Double = 0.4,
                maxTokens: Int? = nil,
                stopSequences: [String] = [],
                model: String? = nil) {
        self.messages = messages; self.tools = tools; self.temperature = temperature
        self.maxTokens = maxTokens; self.stopSequences = stopSequences; self.model = model
    }
}
