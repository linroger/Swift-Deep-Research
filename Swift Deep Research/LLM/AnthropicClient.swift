import Foundation

/// Anthropic Messages API with SSE streaming and tool use.
/// Implemented directly against the REST endpoint — no SDK dependency.
public struct AnthropicClient: LLMClient {
    public let identity: LLMClientIdentity
    private let apiKey: String
    private let model: String
    private let baseURL: URL
    private let session: URLSession
    private let anthropicVersion = "2023-06-01"

    public init(apiKey: String,
                model: String = "claude-sonnet-4-20250514",
                baseURL: URL = URL(string: "https://api.anthropic.com")!,
                session: URLSession = HTTPClientCommon.defaultSession(timeout: 300)) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.session = session
        self.identity = LLMClientIdentity(
            providerID: "anthropic",
            displayName: "Anthropic — \(model)",
            defaultModel: model,
            availableModels: [
                "claude-opus-4-1-20250805",
                "claude-opus-4-20250514",
                "claude-sonnet-4-20250514",
                "claude-3-7-sonnet-20250219",
                "claude-3-5-haiku-20241022"
            ],
            supportsToolCalling: true,
            contextWindow: 200_000
        )
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard !apiKey.isEmpty else {
                    continuation.yield(.finished(reason: .error))
                    continuation.finish(throwing: EngineFailure(kind: .configurationMissing,
                                                                message: "Anthropic API key not set."))
                    return
                }
                let body: Data
                do {
                    body = try Self.encodeBody(request: request, defaultModel: model, stream: true)
                } catch {
                    continuation.yield(.finished(reason: .error))
                    continuation.finish(throwing: error)
                    return
                }
                // Transient retry: reasoning models can idle before the first
                // token and drop the connection, and the gateway can return a
                // transient 429/5xx. Retry as long as we have NOT yet started
                // streaming tokens to the consumer, so output is never
                // duplicated. checkOK throws an EngineFailure(.providerFailure)
                // ("Anthropic HTTP 503", overloaded, ...) BEFORE any token is
                // yielded, so a transient one is safely retried; once the SSE
                // loop begins, a drop is mid-stream and fatal (no retry).
                // RetryPolicy.isTransient is the single source of truth.
                let maxAttempts = 3
                var attempt = 0
                while true {
                    attempt += 1
                    var streamingBegan = false
                    do {
                        var url = URLRequest(url: baseURL.appending(path: "/v1/messages"))
                        url.httpMethod = "POST"
                        url.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        url.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                        url.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
                        url.httpBody = body

                        let (bytes, response) = try await session.bytes(for: url)
                        try await Self.checkOK(response: response, bytes: bytes)
                        // Past the status gate: a later drop is mid-stream and
                        // must not be retried (partial output already delivered).
                        streamingBegan = true

                        var toolBlockIDs: [Int: String] = [:]
                        var inputTokens = 0
                        for try await event in SSEParser.stream(bytes) {
                            try Self.handle(event: event,
                                            toolBlockIDs: &toolBlockIDs,
                                            inputTokens: &inputTokens,
                                            into: continuation)
                        }
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                        return
                    } catch {
                        if !streamingBegan, attempt < maxAttempts, RetryPolicy.isTransient(error) {
                            try? await Task.sleep(for: .seconds(Double(attempt) * 0.7))
                            continue
                        }
                        continuation.yield(.finished(reason: .error))
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Body encoding

    private static func encodeBody(request: LLMRequest,
                                   defaultModel: String,
                                   stream: Bool) throws -> Data {
        struct Body: Encodable {
            let model: String
            let max_tokens: Int
            let temperature: Double
            let stream: Bool
            let system: String?
            let messages: [WireMessage]
            let tools: [WireTool]?
            let stop_sequences: [String]?
        }
        struct WireMessage: Encodable {
            let role: String
            let content: [WireBlock]
        }
        enum WireBlock: Encodable {
            case text(String)
            case toolUse(id: String, name: String, input: AnyJSON)
            case toolResult(toolUseID: String, content: String)

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .text(let s):
                    try c.encode("text", forKey: .type)
                    try c.encode(s, forKey: .text)
                case .toolUse(let id, let name, let input):
                    try c.encode("tool_use", forKey: .type)
                    try c.encode(id, forKey: .id)
                    try c.encode(name, forKey: .name)
                    try c.encode(input, forKey: .input)
                case .toolResult(let id, let content):
                    try c.encode("tool_result", forKey: .type)
                    try c.encode(id, forKey: .tool_use_id)
                    try c.encode(content, forKey: .content)
                }
            }
            enum CodingKeys: String, CodingKey {
                case type, text, id, name, input, tool_use_id, content
            }
        }
        struct WireTool: Encodable {
            let name: String
            let description: String
            let input_schema: AnyJSON
        }

        var system: String?
        var messages: [WireMessage] = []
        for m in request.messages {
            switch m.role {
            case .system:
                let text = m.plainText
                system = (system.map { $0 + "\n\n" } ?? "") + text
            case .user, .assistant:
                var blocks: [WireBlock] = []
                for block in m.content {
                    switch block {
                    case .text(let s): blocks.append(.text(s))
                    case .toolCall(let id, let name, let args):
                        blocks.append(.toolUse(id: id, name: name,
                                               input: (try? AnyJSON.parse(args)) ?? .null))
                    case .toolResult(let id, _, let output):
                        blocks.append(.toolResult(toolUseID: id, content: output))
                    }
                }
                if blocks.isEmpty { blocks.append(.text("")) }
                messages.append(WireMessage(role: m.role.rawValue, content: blocks))
            case .tool:
                // Anthropic encodes tool results as a user message containing tool_result blocks.
                var blocks: [WireBlock] = []
                for block in m.content {
                    if case .toolResult(let id, _, let output) = block {
                        blocks.append(.toolResult(toolUseID: id, content: output))
                    }
                }
                if !blocks.isEmpty {
                    messages.append(WireMessage(role: "user", content: blocks))
                }
            }
        }

        let wireTools = request.tools.isEmpty ? nil : request.tools.map {
            WireTool(name: $0.name,
                     description: $0.description,
                     input_schema: (try? AnyJSON.parse($0.parametersJSONSchema)) ?? .null)
        }

        let resolvedModel = request.model ?? defaultModel
        let body = Body(
            model: resolvedModel,
            // Anthropic requires max_tokens. Pick the model's actual ceiling
            // rather than capping at 4k — Haiku is 8k, Opus 32k, Sonnet 64k.
            max_tokens: request.maxTokens ?? Self.modelMaxOutput(for: resolvedModel),
            temperature: request.temperature,
            stream: stream,
            system: system,
            messages: messages,
            tools: wireTools,
            stop_sequences: request.stopSequences.isEmpty ? nil : request.stopSequences
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(body)
    }

    /// Per-family output-token ceiling. Anthropic 400s if `max_tokens` exceeds
    /// the model's supported limit, so we cap by family.
    private static func modelMaxOutput(for model: String) -> Int {
        let m = model.lowercased()
        if m.contains("haiku") { return 8_192 }
        if m.contains("opus")  { return 32_000 }
        return 64_000   // Sonnet, generic
    }

    // MARK: - Event handling

    private static func handle(event: SSEParser.Event,
                               toolBlockIDs: inout [Int: String],
                               inputTokens: inout Int,
                               into continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation) throws {
        guard let data = event.data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "message_start":
            // Anthropic reports prompt-side usage (input_tokens + cache read/
            // creation) only here. `complete()` does last-wins on the usage
            // tuple, so we stash it and emit ONE combined usage at message_delta;
            // otherwise the (often large) system-prompt input is never counted
            // and the token budget under-enforces.
            if let message = obj["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                let input = (usage["input_tokens"] as? Int) ?? 0
                let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                inputTokens = input + cacheRead + cacheCreate
            }
        case "content_block_start":
            if let cb = obj["content_block"] as? [String: Any],
               (cb["type"] as? String) == "tool_use",
               let id = cb["id"] as? String,
               let name = cb["name"] as? String {
                if let idx = obj["index"] as? Int {
                    toolBlockIDs[idx] = id
                }
                continuation.yield(.toolCallStart(id: id, name: name))
            }
        case "content_block_delta":
            guard let delta = obj["delta"] as? [String: Any],
                  let kind = delta["type"] as? String else { return }
            if kind == "text_delta", let t = delta["text"] as? String {
                continuation.yield(.text(t))
            } else if kind == "input_json_delta",
                      let p = delta["partial_json"] as? String,
                      let idx = obj["index"] as? Int {
                let id = toolBlockIDs[idx] ?? "block-\(idx)"
                continuation.yield(.toolCallArgumentsDelta(id: id, delta: p))
            }
        case "content_block_stop":
            if let idx = obj["index"] as? Int {
                let id = toolBlockIDs.removeValue(forKey: idx) ?? "block-\(idx)"
                continuation.yield(.toolCallEnd(id: id))
            }
        case "message_delta":
            if let usage = obj["usage"] as? [String: Any],
               let out = usage["output_tokens"] as? Int {
                continuation.yield(.usage(promptTokens: inputTokens, completionTokens: out))
            }
        case "message_stop":
            continuation.yield(.finished(reason: .stop))
        case "error":
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "Anthropic error"
            throw EngineFailure(kind: .providerFailure, message: msg)
        default: break
        }
    }

    private static func checkOK(response: URLResponse,
                                bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else {
            throw EngineFailure(kind: .providerFailure, message: "Anthropic: no HTTP response")
        }
        guard !(200..<300 ~= http.statusCode) else { return }
        // Drain a bounded prefix of the error body so the user sees Anthropic's
        // real message (invalid key, model not found, rate limit, overloaded)
        // instead of a bare "HTTP 4xx". Anthropic returns
        // {"error":{"type":...,"message":...}}. The drain is best-effort: a
        // transport error mid-read falls back to whatever bytes arrived (and a
        // status-only message), so the user still sees the HTTP code.
        let data = try await HTTPErrorMapping.drainBody(from: bytes, cap: 2048, bestEffort: true)
        let detail = Self.extractErrorMessage(data)
        throw EngineFailure(kind: .providerFailure,
                            message: "Anthropic HTTP \(http.statusCode)" + (detail.map { ": \($0)" } ?? ""),
                            underlying: detail)
    }

    /// Pull `error.message` from Anthropic's error JSON, falling back to a short
    /// raw-text prefix when the body isn't the expected shape.
    private static func extractErrorMessage(_ data: Data) -> String? {
        if let obj = HTTPErrorMapping.parseJSONObject(from: data),
           let msg = HTTPErrorMapping.nestedErrorMessage(in: obj) {
            return msg
        }
        return HTTPErrorMapping.rawTextPrefix(from: data, limit: 500)
    }
}
