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
    /// Memoizes the resolved num_ctx per model so we only probe `/api/show`
    /// once per (host, model) for the lifetime of the client. An actor keeps
    /// the lookup race-free while staying Sendable, so the surrounding struct
    /// remains Sendable as required by `LLMClient`.
    private let contextCache = ContextWindowCache()

    /// Hard ceiling on the KV-cache context we request. A 131072-token cache
    /// OOMs small Macs (the old hardcoded default); 32768 is a safe upper
    /// bound that still comfortably fits our orchestrator-worker prompts.
    private static let safeContextCeiling = 32_768

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

    /// Per-model memo of the resolved num_ctx. Keyed by model name; the value
    /// is the already-clamped context we will request.
    private actor ContextWindowCache {
        private var resolved: [String: Int] = [:]
        func value(for model: String) -> Int? { resolved[model] }
        func store(_ value: Int, for model: String) { resolved[model] = value }
    }

    /// Resolve the num_ctx to request for `model`, capped at
    /// `safeContextCeiling` and shrunk to the model's advertised
    /// `context_length` when `/api/show` reports a smaller window.
    ///
    /// We probe `/api/show` once per model and memoize the result. If the
    /// probe fails (older Ollama without the endpoint, server unreachable,
    /// unexpected payload), we fall back to the ceiling so the request still
    /// succeeds with a safe, non-OOM context. The probe result is cached even
    /// on the fallback path so a transient miss doesn't re-probe on every call.
    private func resolveNumCtx(for model: String) async -> Int {
        if let cached = await contextCache.value(for: model) { return cached }
        let resolved = await probeContextLength(for: model)
            .map { min($0, Self.safeContextCeiling) }
            ?? Self.safeContextCeiling
        await contextCache.store(resolved, for: model)
        return resolved
    }

    /// Ask Ollama for the model's advertised maximum context length via
    /// `/api/show`. Ollama nests this under `model_info` as an
    /// architecture-prefixed key (e.g. `qwen3.context_length`,
    /// `llama.context_length`), so we scan for any `*.context_length` entry and
    /// also tolerate a bare top-level `context_length`. Returns nil when the
    /// endpoint is unavailable or the field is absent/non-positive.
    private func probeContextLength(for model: String) async -> Int? {
        do {
            var req = URLRequest(url: Self.endpoint(host: host, path: "api/show"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])

            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
                return nil
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if let info = obj["model_info"] as? [String: Any] {
                for (key, value) in info where key.hasSuffix(".context_length") || key == "context_length" {
                    if let n = value as? Int, n > 0 { return n }
                    if let d = value as? Double, d > 0 { return Int(d) }
                }
            }
            if let n = obj["context_length"] as? Int, n > 0 { return n }
            return nil
        } catch {
            Log.net.debug("\(identity.displayName, privacy: .public): /api/show probe failed (\(String(describing: error), privacy: .public)); using default context.")
            return nil
        }
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: Self.endpoint(host: host, path: "api/chat"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let numCtx = await resolveNumCtx(for: request.model ?? model)
                    req.httpBody = try Self.encodeBody(request: request, defaultModel: model, numCtx: numCtx)

                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
                        // Read the body for the real error message (Ollama
                        // returns 404 + `{"error":"model 'X' not found"}` when
                        // the requested model isn't pulled, for instance). The
                        // cap is 4097 so the bounded read stops at the same point
                        // the previous `count > 4096` loop did.
                        let data = try await HTTPErrorMapping.drainBody(from: bytes, cap: 4097)
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
                    // Track terminal-marker arrival so a mid-stream drop after
                    // 200 OK isn't silently treated as a clean answer. Ollama's
                    // final NDJSON object carries `"done": true`; if the byte
                    // stream ends before we see it (model crash, OOM, server
                    // restart), we surface truncation instead of finishing clean.
                    var sawDone = false
                    var producedOutput = false
                    for try await byte in bytes {
                        if byte == 0x0A {
                            let line = String(decoding: buffer, as: UTF8.self)
                            buffer.removeAll(keepingCapacity: true)
                            guard !line.isEmpty,
                                  let data = line.data(using: .utf8),
                                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                            else { continue }

                            if let msg = obj["message"] as? [String: Any] {
                                if let text = msg["content"] as? String, !text.isEmpty {
                                    continuation.yield(.text(text))
                                    producedOutput = true
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
                                        producedOutput = true
                                    }
                                }
                            }
                            if (obj["done"] as? Bool) == true {
                                sawDone = true
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
                    // The byte stream ended without a `"done": true` line. A
                    // dropped connection mid-generation otherwise masquerades as
                    // a clean finish and silently truncates the answer. Mirror
                    // OpenAICompatibleClient: keep any partial output but flag it
                    // as cut short, or surface a hard failure when nothing arrived.
                    if !sawDone {
                        if producedOutput {
                            Log.net.warning("\(identity.displayName, privacy: .public): Ollama stream closed without a done:true marker — output may be truncated.")
                            // Close out any tool calls left dangling without a
                            // done line so the worker doesn't wait on them.
                            for id in emittedCallIDs {
                                continuation.yield(.toolCallEnd(id: id))
                            }
                            continuation.yield(.finished(reason: .length))
                        } else {
                            // Nothing arrived before the close — a failed stream,
                            // not an empty answer. Surface it rather than reporting
                            // a clean, empty completion.
                            throw EngineFailure(
                                kind: .providerFailure,
                                message: "\(identity.displayName): the model stream ended before any output (dropped connection). Try again."
                            )
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

    private static func encodeBody(request: LLMRequest, defaultModel: String, numCtx: Int) throws -> Data {
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
        // worker prompts (system + tool outputs + history). The value is
        // resolved by `resolveNumCtx(for:)`: we cap at `safeContextCeiling`
        // (32k) instead of pinning 128k, since a 131072-token KV cache OOMs
        // small Macs, and shrink further to the model's own advertised
        // `context_length` when `/api/show` reports a smaller window.
        // num_predict left nil so the model uses its own max output length.
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
                         num_ctx: numCtx),
            tools: tools
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(body)
    }
}
