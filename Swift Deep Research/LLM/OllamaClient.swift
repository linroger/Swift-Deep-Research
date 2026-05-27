import Foundation

/// Ollama local server provider. Hits /api/chat with stream=true.
///
/// Recent Ollama releases support OpenAI-style function calling for compatible
/// models (qwen2.5, llama3.3, gpt-oss, mistral-small, etc.). We pass tool
/// specs in the request body and decode `message.tool_calls` from each NDJSON
/// chunk into the provider-agnostic LLMStreamChunk events the worker loop
/// expects. Without this wiring, the LLM never learns about the available
/// tools and silently degrades to free-text answers — the exact failure mode
/// that left knowledge_base and web_search uninvoked.
public struct OllamaClient: LLMClient {
    public let identity: LLMClientIdentity
    private let host: URL
    private let model: String
    private let session: URLSession

    public init(host: URL = URL(string: "http://localhost:11434")!,
                model: String = "qwen3:8b",
                session: URLSession = HTTPClientCommon.defaultSession(timeout: 600)) {
        self.host = host
        self.model = model
        self.session = session
        self.identity = LLMClientIdentity(
            providerID: "ollama",
            displayName: "Ollama — \(model)",
            defaultModel: model,
            availableModels: ["qwen3:8b", "qwen2.5:7b", "llama3.3:70b", "deepseek-r1:14b", "mistral-small:24b"],
            supportsToolCalling: true,
            contextWindow: 131_072
        )
    }

    public static func listModels(host: URL = URL(string: "http://localhost:11434")!,
                                  session: URLSession = HTTPClientCommon.defaultSession()) async throws -> [String] {
        let url = Self.endpoint(host: host, path: "api/tags")
        let (data, _) = try await session.data(from: url)
        struct Resp: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        return resp.models.map(\.name).sorted()
    }

    /// Build a clean Ollama endpoint URL by string concat — `URL.appending(path:)`
    /// produces double-slashes when the base host has no trailing slash and the
    /// path starts with `/`, which makes Ollama return 404.
    private static func endpoint(host: URL, path: String) -> URL {
        var base = host.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        return URL(string: "\(base)/\(path)")!
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: Self.endpoint(host: host, path: "api/chat"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try Self.encodeBody(request: request, defaultModel: model)

                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
                        // Read the body for the real error message (Ollama
                        // returns 404 + `{"error":"model 'X' not found"}` when
                        // the requested model isn't pulled, for instance).
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 4096 { break }
                        }
                        let body = String(data: data, encoding: .utf8) ?? ""
                        let snippet = body.replacingOccurrences(of: "\n", with: " ")
                                          .trimmingCharacters(in: .whitespaces)
                                          .prefix(280)
                        throw EngineFailure(
                            kind: .providerFailure,
                            message: "Ollama HTTP \(http.statusCode) — \(snippet.isEmpty ? "no body" : String(snippet))"
                        )
                    }

                    // Ollama streams line-delimited JSON, not SSE.
                    var buffer = Data()
                    // Synthetic call IDs scoped to this stream — Ollama doesn't
                    // emit IDs for tool calls, so we mint our own so the worker
                    // loop can correlate the assistant tool_call block with the
                    // subsequent tool_result message.
                    var toolCallCounter = 0
                    var emittedCallIDs: [String] = []
                    for try await byte in bytes {
                        if byte == 0x0A {
                            let line = String(decoding: buffer, as: UTF8.self)
                            buffer.removeAll(keepingCapacity: true)
                            guard !line.isEmpty,
                                  let data = line.data(using: .utf8),
                                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                            else { continue }

                            if let msg = obj["message"] as? [String: Any] {
                                if let text = msg["content"] as? String, !text.isEmpty {
                                    continuation.yield(.text(text))
                                }
                                if let calls = msg["tool_calls"] as? [[String: Any]] {
                                    for call in calls {
                                        guard let fn = call["function"] as? [String: Any],
                                              let name = fn["name"] as? String else { continue }
                                        let id: String
                                        if let provided = call["id"] as? String, !provided.isEmpty {
                                            id = provided
                                        } else {
                                            toolCallCounter += 1
                                            id = "ollama-\(toolCallCounter)-\(UUID().uuidString.prefix(8))"
                                        }
                                        // Ollama returns arguments as either a
                                        // JSON object or a pre-serialized
                                        // string depending on the model. The
                                        // worker expects a JSON string, so
                                        // normalize both shapes.
                                        let argsJSON: String = {
                                            if let s = fn["arguments"] as? String { return s }
                                            if let obj = fn["arguments"] {
                                                if let data = try? JSONSerialization.data(withJSONObject: obj),
                                                   let s = String(data: data, encoding: .utf8) {
                                                    return s
                                                }
                                            }
                                            return "{}"
                                        }()
                                        continuation.yield(.toolCallStart(id: id, name: name))
                                        continuation.yield(.toolCallArgumentsDelta(id: id, delta: argsJSON))
                                        emittedCallIDs.append(id)
                                    }
                                }
                            }
                            if (obj["done"] as? Bool) == true {
                                for id in emittedCallIDs {
                                    continuation.yield(.toolCallEnd(id: id))
                                }
                                emittedCallIDs.removeAll()
                                let p = (obj["prompt_eval_count"] as? Int) ?? 0
                                let c = (obj["eval_count"] as? Int) ?? 0
                                continuation.yield(.usage(promptTokens: p, completionTokens: c))
                                let reason: LLMStreamChunk.FinishReason
                                if let why = obj["done_reason"] as? String {
                                    reason = switch why {
                                    case "stop": .stop
                                    case "length": .length
                                    case "tool_use", "tool_calls": .toolUse
                                    default: .stop
                                    }
                                } else {
                                    reason = .stop
                                }
                                continuation.yield(.finished(reason: reason))
                            }
                        } else {
                            buffer.append(byte)
                        }
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
            let messages: [Msg]
            let options: Opts
            let tools: [WireTool]?
        }
        // Ollama accepts assistant messages with tool_calls and `tool`-role
        // messages with a tool_call_id. Mirroring OpenAI's shape keeps
        // multi-turn tool conversations consistent across providers.
        struct Msg: Encodable {
            let role: String
            let content: String
            let tool_calls: [WireToolCall]?
            let tool_call_id: String?
            let name: String?
        }
        struct WireToolCall: Encodable {
            let id: String?
            let type: String
            let function: WireFnCall
            init(id: String?, function: WireFnCall) {
                self.id = id; self.type = "function"; self.function = function
            }
        }
        struct WireFnCall: Encodable { let name: String; let arguments: AnyJSON }
        struct WireTool: Encodable {
            let type: String
            let function: WireToolFn
            init(function: WireToolFn) { self.type = "function"; self.function = function }
        }
        struct WireToolFn: Encodable {
            let name: String
            let description: String
            let parameters: AnyJSON
        }
        // num_ctx widens Ollama's context window from its conservative
        // 2048-token default to a value large enough for our orchestrator-
        // worker prompts (system + tool outputs + history). 128k is the
        // ceiling most modern local models advertise; Ollama will clamp to
        // the model's actual capacity if smaller. num_predict left nil so
        // the model uses its own max output length.
        struct Opts: Encodable {
            let temperature: Double
            let num_predict: Int?
            let num_ctx: Int
        }

        var messages: [Msg] = []
        for m in request.messages {
            switch m.role {
            case .system, .user, .assistant:
                var text = ""
                var toolCalls: [WireToolCall] = []
                for block in m.content {
                    switch block {
                    case .text(let s):
                        text += s
                    case .toolCall(let id, let name, let args):
                        let parsed = (try? AnyJSON.parse(args)) ?? .object([:])
                        toolCalls.append(WireToolCall(id: id,
                                                      function: WireFnCall(name: name, arguments: parsed)))
                    case .toolResult:
                        break
                    }
                }
                messages.append(Msg(role: m.role.rawValue,
                                    content: text,
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

        let tools: [WireTool]? = request.tools.isEmpty ? nil : request.tools.map { t in
            WireTool(function: WireToolFn(
                name: t.name,
                description: t.description,
                parameters: (try? AnyJSON.parse(t.parametersJSONSchema)) ?? .object([:])
            ))
        }

        let body = Body(
            model: request.model ?? defaultModel,
            stream: true,
            messages: messages,
            options: Opts(temperature: request.temperature,
                         num_predict: request.maxTokens,
                         num_ctx: 131_072),
            tools: tools
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(body)
    }
}
