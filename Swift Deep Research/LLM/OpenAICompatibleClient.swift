import Foundation

/// One client for every provider that speaks the OpenAI Chat Completions wire
/// format. DeepSeek, MiniMax, Moonshot/Kimi, LM Studio, and arbitrary custom
/// endpoints all expose `/v1/chat/completions` with the same request/response
/// shape, so a single, well-tested implementation serves all of them.
///
/// `OpenAIClient` itself is a thin wrapper over this type — there is exactly one
/// copy of the SSE parsing and tool-call buffering logic in the codebase.
public struct OpenAICompatibleClient: LLMClient {
    public let identity: LLMClientIdentity
    private let apiKey: String
    private let model: String
    /// Fully-resolved chat-completions endpoint (e.g.
    /// `https://api.deepseek.com/v1/chat/completions`).
    private let endpoint: URL
    private let session: URLSession
    /// Local servers (LM Studio, Ollama-compat) accept requests with no key.
    private let requiresKey: Bool
    /// Newer OpenAI models require `max_completion_tokens`; virtually every
    /// third-party OpenAI-compatible server still wants the classic
    /// `max_tokens`. We pick the right field per provider.
    private let tokenParameter: TokenParameter

    public enum TokenParameter: Sendable { case completion, legacy }

    public init(apiKey: String,
                model: String,
                baseURL: URL,
                identity: LLMClientIdentity,
                requiresKey: Bool = true,
                tokenParameter: TokenParameter = .legacy,
                session: URLSession = HTTPClientCommon.defaultSession(timeout: 300)) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = Self.resolveChatCompletionsURL(base: baseURL)
        self.identity = identity
        self.requiresKey = requiresKey
        self.tokenParameter = tokenParameter
        self.session = session
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if requiresKey && apiKey.isEmpty {
                        throw EngineFailure(kind: .configurationMissing,
                                            message: "\(identity.displayName): API key not set.")
                    }
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !apiKey.isEmpty {
                        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    req.httpBody = try Self.encodeBody(request: request,
                                                       defaultModel: model,
                                                       tokenParameter: tokenParameter)

                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
                        // Drain a short body snippet for an actionable error.
                        var snippet = ""
                        for try await line in bytes.lines {
                            snippet += line + "\n"
                            if snippet.count > 600 { break }
                        }
                        throw EngineFailure(
                            kind: http.statusCode == 401 || http.statusCode == 403
                                ? .configurationMissing : .providerFailure,
                            message: "\(identity.displayName) HTTP \(http.statusCode)",
                            underlying: snippet.isEmpty ? nil : String(snippet.prefix(600)))
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

    // MARK: - Endpoint resolution

    /// Normalize a base URL into a chat-completions endpoint. Accepts any of:
    ///   - `https://api.deepseek.com`              → …/v1/chat/completions
    ///   - `https://api.deepseek.com/v1`           → …/v1/chat/completions
    ///   - `http://localhost:1234/v1/chat/completions` (used as-is)
    /// so users pasting a custom endpoint in any common form still work.
    static func resolveChatCompletionsURL(base: URL) -> URL {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        let lower = s.lowercased()
        if lower.hasSuffix("/chat/completions") {
            return URL(string: s) ?? base
        }
        if lower.hasSuffix("/v1") {
            return URL(string: s + "/chat/completions") ?? base
        }
        return URL(string: s + "/v1/chat/completions") ?? base
    }

    /// Sibling `/v1/models` URL for discovery.
    private static func resolveModelsURL(base: URL) -> URL {
        let chat = resolveChatCompletionsURL(base: base)
        var s = chat.absoluteString
        if let range = s.range(of: "/chat/completions", options: .backwards) {
            s.replaceSubrange(range, with: "/models")
        }
        return URL(string: s) ?? chat
    }

    /// List models the endpoint advertises via the OpenAI-standard
    /// `GET /v1/models`. Used by LM Studio / custom-endpoint discovery in
    /// Settings. Returns sorted model ids; throws on transport failure.
    public static func listModels(baseURL: URL,
                                  apiKey: String = "",
                                  session: URLSession = HTTPClientCommon.defaultSession(timeout: 8)) async throws -> [String] {
        var req = URLRequest(url: resolveModelsURL(base: baseURL))
        req.httpMethod = "GET"
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw EngineFailure(kind: .providerFailure, message: "models HTTP \(code)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else { return [] }
        let ids = arr.compactMap { $0["id"] as? String }
        return Array(Set(ids)).sorted()
    }

    // MARK: - Body encoding

    private static func encodeBody(request: LLMRequest,
                                   defaultModel: String,
                                   tokenParameter: TokenParameter) throws -> Data {
        struct Body: Encodable {
            let model: String
            let stream: Bool
            let temperature: Double
            let max_tokens: Int?
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
                messages.append(Msg(role: m.role.rawValue,
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
            max_tokens: tokenParameter == .legacy ? request.maxTokens : nil,
            max_completion_tokens: tokenParameter == .completion ? request.maxTokens : nil,
            messages: messages,
            tools: tools,
            stop: request.stopSequences.isEmpty ? nil : request.stopSequences
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(body)
    }

    // MARK: - Event parsing

    private static func parseEvent(data: String,
                                   toolBuffer: inout [Int: PartialToolCall],
                                   continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation) throws {
        guard let bytes = data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        // Some servers stream an error object mid-stream rather than via HTTP.
        if let err = obj["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? "provider stream error"
            throw EngineFailure(kind: .providerFailure, message: msg)
        }
        guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first else { return }
        let delta = first["delta"] as? [String: Any] ?? [:]
        if let text = delta["content"] as? String, !text.isEmpty {
            continuation.yield(.text(text))
        }
        // `reasoning_content` (DeepSeek-R1, Kimi thinking) is deliberately not
        // surfaced as answer text — it would contaminate worker summaries and
        // the final synthesis. The model's `content` carries the real answer.
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
