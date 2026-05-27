import Foundation

/// OpenAI Chat Completions with SSE streaming and tool calling.
/// Targets GPT-5.5 and o-series; raw REST so any model name works.
public struct OpenAIClient: LLMClient {
    public let identity: LLMClientIdentity
    private let apiKey: String
    private let model: String
    private let baseURL: URL
    private let session: URLSession

    public init(apiKey: String,
                model: String = "gpt-5.5",
                baseURL: URL = URL(string: "https://api.openai.com")!,
                session: URLSession = HTTPClientCommon.defaultSession(timeout: 120)) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.session = session
        self.identity = LLMClientIdentity(
            providerID: "openai",
            displayName: "OpenAI — \(model)",
            defaultModel: model,
            availableModels: [
                "gpt-5.5",
                "gpt-5.5-2026-04-23",
                "gpt-5.4",
                "gpt-5.4-mini",
                "gpt-5.4-nano",
                "gpt-5",
                "gpt-4.1"
            ],
            supportsToolCalling: true,
            contextWindow: 400_000
        )
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else {
                        throw EngineFailure(kind: .configurationMissing,
                                            message: "OpenAI API key not set.")
                    }
                    var req = URLRequest(url: baseURL.appending(path: "/v1/chat/completions"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    req.httpBody = try Self.encodeBody(request: request, defaultModel: model)

                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
                        throw EngineFailure(kind: .providerFailure,
                                            message: "OpenAI HTTP \(http.statusCode)")
                    }
                    var toolBuffer: [Int: PartialToolCall] = [:]
                    for try await event in SSEParser.stream(bytes) {
                        if event.data == "[DONE]" {
                            for (_, call) in toolBuffer { continuation.yield(.toolCallEnd(id: call.id)) }
                            continuation.yield(.finished(reason: .stop))
                            break
                        }
                        try Self.parseEvent(data: event.data,
                                            toolBuffer: &toolBuffer,
                                            continuation: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.finished(reason: .error))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func encodeBody(request: LLMRequest, defaultModel: String) throws -> Data {
        struct Body: Encodable {
            let model: String
            let stream: Bool
            let temperature: Double
            let max_completion_tokens: Int?
            let messages: [Msg]
            let tools: [WireTool]?
            let stop: [String]?
        }
        struct Msg: Encodable {
            let role: String
            let content: String?
            let tool_calls: [WireToolCall]?
            let tool_call_id: String?
            let name: String?
        }
        struct WireToolCall: Encodable {
            let id: String
            let type: String = "function"
            let function: WireFn
        }
        struct WireFn: Encodable { let name: String; let arguments: String }
        struct WireTool: Encodable {
            let type: String = "function"
            let function: WireToolFn
        }
        struct WireToolFn: Encodable {
            let name: String
            let description: String
            let parameters: AnyJSON
        }

        var messages: [Msg] = []
        for m in request.messages {
            switch m.role {
            case .system, .user, .assistant:
                var text = ""
                var toolCalls: [WireToolCall] = []
                for block in m.content {
                    switch block {
                    case .text(let s): text += s
                    case .toolCall(let id, let name, let args):
                        toolCalls.append(WireToolCall(id: id,
                                                      function: WireFn(name: name, arguments: args)))
                    case .toolResult: break
                    }
                }
                let role = m.role.rawValue
                messages.append(Msg(role: role,
                                    content: text.isEmpty && !toolCalls.isEmpty ? nil : text,
                                    tool_calls: toolCalls.isEmpty ? nil : toolCalls,
                                    tool_call_id: nil,
                                    name: nil))
            case .tool:
                for block in m.content {
                    if case .toolResult(let id, let name, let output) = block {
                        messages.append(Msg(role: "tool",
                                            content: output,
                                            tool_calls: nil,
                                            tool_call_id: id,
                                            name: name))
                    }
                }
            }
        }

        let tools = request.tools.isEmpty ? nil : request.tools.map { t in
            WireTool(function: WireToolFn(
                name: t.name,
                description: t.description,
                parameters: (try? AnyJSON.parse(t.parametersJSONSchema)) ?? .null
            ))
        }

        let body = Body(
            model: request.model ?? defaultModel,
            stream: true,
            temperature: request.temperature,
            max_completion_tokens: request.maxTokens,
            messages: messages,
            tools: tools,
            stop: request.stopSequences.isEmpty ? nil : request.stopSequences
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(body)
    }

    private static func parseEvent(data: String,
                                   toolBuffer: inout [Int: PartialToolCall],
                                   continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation) throws {
        guard let bytes = data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first else { return }
        let delta = first["delta"] as? [String: Any] ?? [:]
        if let text = delta["content"] as? String, !text.isEmpty {
            continuation.yield(.text(text))
        }
        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for entry in toolCalls {
                guard let index = entry["index"] as? Int else { continue }
                let fn = entry["function"] as? [String: Any] ?? [:]
                let id = entry["id"] as? String ?? toolBuffer[index]?.id ?? "tc-\(index)"
                let name = (fn["name"] as? String) ?? toolBuffer[index]?.name ?? ""
                if toolBuffer[index] == nil {
                    toolBuffer[index] = PartialToolCall(id: id, name: name, argumentsJSON: "")
                    continuation.yield(.toolCallStart(id: id, name: name))
                }
                if let args = fn["arguments"] as? String, !args.isEmpty {
                    toolBuffer[index]?.argumentsJSON += args
                    continuation.yield(.toolCallArgumentsDelta(id: id, delta: args))
                }
            }
        }
        if let finish = first["finish_reason"] as? String {
            let reason: LLMStreamChunk.FinishReason = switch finish {
            case "stop": .stop
            case "length": .length
            case "tool_calls": .toolUse
            case "content_filter": .contentFilter
            default: .stop
            }
            continuation.yield(.finished(reason: reason))
        }
        if let usage = obj["usage"] as? [String: Any] {
            let p = usage["prompt_tokens"] as? Int ?? 0
            let c = usage["completion_tokens"] as? Int ?? 0
            continuation.yield(.usage(promptTokens: p, completionTokens: c))
        }
    }
}
