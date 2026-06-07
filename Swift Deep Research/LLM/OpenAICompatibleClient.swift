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
                if requiresKey && apiKey.isEmpty {
                    continuation.yield(.finished(reason: .error))
                    continuation.finish(throwing: EngineFailure(
                        kind: .configurationMissing,
                        message: "\(identity.displayName): API key not set."))
                    return
                }
                let body: Data
                do {
                    body = try Self.encodeBody(request: request,
                                               defaultModel: model,
                                               tokenParameter: tokenParameter)
                } catch {
                    continuation.yield(.finished(reason: .error))
                    continuation.finish(throwing: error)
                    return
                }

                // Retry transient connection failures, but ONLY before the
                // server has sent anything — once we've yielded content, a retry
                // would duplicate output. Slow reasoning models (deepseek-reasoner,
                // Kimi thinking) idle for many seconds before the first token, and
                // intermediaries drop the idle connection ("network connection
                // lost"); a fresh attempt almost always succeeds.
                let maxAttempts = 3
                var attempt = 0
                while true {
                    attempt += 1
                    var serverResponded = false
                    do {
                        var req = URLRequest(url: endpoint)
                        req.httpMethod = "POST"
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        if !apiKey.isEmpty {
                            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                        }
                        req.httpBody = body

                        let (bytes, response) = try await session.bytes(for: req)
                        if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
                            // Drain the error body so we can extract the provider's
                            // own message (e.g. DeepSeek's "Insufficient Balance").
                            // A 4xx/5xx is a definitive answer — never retry it.
                            serverResponded = true
                            var errBody = ""
                            for try await line in bytes.lines {
                                errBody += line + "\n"
                                if errBody.count > 1200 { break }
                            }
                            throw Self.httpError(status: http.statusCode,
                                                 body: errBody,
                                                 provider: identity.displayName)
                        }
                        var toolBuffer: [Int: PartialToolCall] = [:]
                        var sawTerminal = false   // [DONE] or an explicit finish_reason
                        var producedOutput = false
                        for try await event in SSEParser.stream(bytes) {
                            serverResponded = true   // past the safe-retry window
                            if event.data == "[DONE]" {
                                for (_, call) in toolBuffer { continuation.yield(.toolCallEnd(id: call.id)) }
                                continuation.yield(.finished(reason: .stop))
                                sawTerminal = true
                                break
                            }
                            try Self.parseEvent(data: event.data,
                                                toolBuffer: &toolBuffer,
                                                sawFinish: &sawTerminal,
                                                producedOutput: &producedOutput,
                                                continuation: continuation)
                        }
                        // The byte stream ended without a terminal marker. A
                        // dropped connection mid-stream otherwise masquerades as a
                        // clean finish and silently truncates the answer.
                        if !sawTerminal {
                            if producedOutput {
                                // Keep the partial output (re-streaming would
                                // duplicate it) but flag it and tell consumers it
                                // was cut short rather than a clean stop.
                                Log.net.warning("\(identity.displayName, privacy: .public): stream closed without a terminal event — output may be truncated.")
                                for (_, call) in toolBuffer { continuation.yield(.toolCallEnd(id: call.id)) }
                                continuation.yield(.finished(reason: .length))
                            } else {
                                // Nothing arrived before the close — a failed
                                // stream, not an empty answer. Surface it.
                                throw EngineFailure(kind: .providerFailure,
                                                    message: "\(identity.displayName): the model stream ended before any output (dropped connection). Try again.")
                            }
                        }
                        continuation.finish()
                        return
                    } catch {
                        if !serverResponded, attempt < maxAttempts, Self.isTransient(error) {
                            // Linear backoff: 0.7s, 1.4s.
                            try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
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

    /// Transient transport failures worth a quick retry (connection dropped
    /// while idle, DNS hiccup, timeout). Never retries cancellation or HTTP
    /// status errors.
    private static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
             .resourceUnavailable, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    // MARK: - Error mapping

    /// Turn a non-2xx HTTP response into an actionable `EngineFailure`. Extracts
    /// the provider's own error message from the JSON body (OpenAI-compatible
    /// error shape) and maps common status codes to plain-language guidance so a
    /// bare "HTTP 402" becomes "payment required — account balance is likely
    /// empty."
    static func httpError(status: Int, body: String, provider: String) -> EngineFailure {
        let detail = extractErrorMessage(from: body)
        let suffix = detail.map { " — \($0)" } ?? ""
        let kind: EngineFailure.Kind
        let message: String
        switch status {
        case 401, 403:
            kind = .configurationMissing
            message = "\(provider): authentication failed (HTTP \(status)). Check the API key in Settings → API keys.\(suffix)"
        case 402:
            kind = .configurationMissing
            message = "\(provider): payment required (HTTP 402). Your account balance is likely empty — add credit, or switch to another provider in Settings.\(suffix)"
        case 429:
            kind = .providerFailure
            message = "\(provider): rate limited (HTTP 429). Slow down or check your plan's limits.\(suffix)"
        case 404:
            kind = .providerFailure
            message = "\(provider): not found (HTTP 404). The model id may be wrong for this endpoint.\(suffix)"
        case 400, 422:
            kind = .providerFailure
            message = "\(provider): request rejected (HTTP \(status)). The model may not support tools, or the model id is invalid.\(suffix)"
        case 500...599:
            kind = .providerFailure
            message = "\(provider): server error (HTTP \(status)). Try again shortly.\(suffix)"
        default:
            kind = .providerFailure
            message = "\(provider): HTTP \(status).\(suffix)"
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return EngineFailure(kind: kind, message: message,
                             underlying: trimmed.isEmpty ? nil : String(trimmed.prefix(600)))
    }

    /// Pull a human message out of an OpenAI-compatible error body:
    /// `{"error":{"message":"…"}}` or `{"message":"…"}`.
    private static func extractErrorMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let err = obj["error"] as? [String: Any], let m = err["message"] as? String, !m.isEmpty {
            return m
        }
        if let err = obj["error"] as? String, !err.isEmpty { return err }
        if let m = obj["message"] as? String, !m.isEmpty { return m }
        return nil
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

    /// Normalize a streamed `function.arguments` value into a string fragment to
    /// append to the tool-call buffer.
    ///
    /// - A `String` is an incremental fragment (OpenAI spec) → returned as-is.
    /// - A JSON object/array is the *complete* arguments (DashScope / Qwen
    ///   compatible-mode, some Azure deployments) → serialized to a JSON string,
    ///   but only when nothing has been buffered yet for this call. Object
    ///   payloads are whole, not incremental, so emitting once avoids
    ///   concatenating duplicates into invalid JSON if the gateway re-sends it.
    /// - Anything else (nil / NSNull / empty) yields `nil` (skip).
    private static func argumentsFragment(from value: Any?, alreadyBuffered: String) -> String? {
        if let s = value as? String {
            return s.isEmpty ? nil : s
        }
        // Object/array form: only accept it as the first payload for this call.
        guard alreadyBuffered.isEmpty else { return nil }
        if let value, !(value is NSNull),
           JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let json = String(data: data, encoding: .utf8),
           json != "{}", json != "[]" {
            return json
        }
        return nil
    }

    private static func parseEvent(data: String,
                                   toolBuffer: inout [Int: PartialToolCall],
                                   sawFinish: inout Bool,
                                   producedOutput: inout Bool,
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
            producedOutput = true
            continuation.yield(.text(text))
        }
        // `reasoning_content` (DeepSeek-R1, Kimi thinking) is deliberately not
        // surfaced as answer text — it would contaminate worker summaries and
        // the final synthesis. The model's `content` carries the real answer.
        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for entry in toolCalls {
                // Most servers always include `index` when streaming tool calls.
                // Some (notably non-streaming-style single calls) omit it; default
                // to 0 so the call isn't silently dropped.
                let index = entry["index"] as? Int ?? 0
                let fn = entry["function"] as? [String: Any] ?? [:]
                let id = entry["id"] as? String ?? toolBuffer[index]?.id ?? "tc-\(index)"
                let name = (fn["name"] as? String) ?? toolBuffer[index]?.name ?? ""
                if toolBuffer[index] == nil {
                    toolBuffer[index] = PartialToolCall(id: id, name: name, argumentsJSON: "")
                    producedOutput = true
                    continuation.yield(.toolCallStart(id: id, name: name))
                }
                // Coerce the `arguments` payload to a JSON string. The OpenAI spec
                // streams it as incremental string fragments, but some compatible
                // gateways (Alibaba DashScope / Qwen compatible-mode) deliver the
                // *complete arguments object* in a single chunk instead. Without
                // this, the object-form cast `as? String` failed silently, the tool
                // received an empty argument string, and every call died with
                // "arguments invalid / couldn't be read".
                if let args = Self.argumentsFragment(from: fn["arguments"],
                                                     alreadyBuffered: toolBuffer[index]?.argumentsJSON ?? "") {
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
            sawFinish = true
            continuation.yield(.finished(reason: reason))
        }
        if let usage = obj["usage"] as? [String: Any] {
            let p = usage["prompt_tokens"] as? Int ?? 0
            let c = usage["completion_tokens"] as? Int ?? 0
            producedOutput = true
            continuation.yield(.usage(promptTokens: p, completionTokens: c))
        }
    }
}
