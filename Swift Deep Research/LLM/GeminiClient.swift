import Foundation

/// Google Gemini generateContent + streamGenerateContent over REST.
public struct GeminiClient: LLMClient {
    public let identity: LLMClientIdentity
    private let apiKey: String
    private let model: String
    private let baseURL: URL
    private let session: URLSession

    public init(apiKey: String,
                model: String = "gemini-3-pro-preview",
                baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!,
                session: URLSession = HTTPClientCommon.defaultSession(timeout: 300)) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.session = session
        self.identity = LLMClientIdentity(
            providerID: "gemini",
            displayName: "Gemini — \(model)",
            defaultModel: model,
            availableModels: [
                "gemini-3-pro-preview",
                "gemini-3-flash-preview",
                "gemini-2.5-pro",
                "gemini-2.5-flash",
                "gemini-2.5-flash-lite",
                "gemini-2.0-flash"
            ],
            supportsToolCalling: true,
            contextWindow: 1_000_000
        )
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard !apiKey.isEmpty else {
                    continuation.yield(.finished(reason: .error))
                    continuation.finish(throwing: EngineFailure(kind: .configurationMissing,
                                                                message: "Gemini API key not set."))
                    return
                }
                let modelID = request.model ?? model
                // Percent-encode the model id in the path and pass the key via the
                // `x-goog-api-key` header rather than a `?key=` query param. The
                // old interpolation put the raw key (and an unescaped model id)
                // straight into the URL string — a malformed key/model could break
                // URL parsing, and the secret leaked into any URL logging.
                let encodedModel = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID
                let urlString = baseURL.absoluteString
                    + "/v1beta/models/\(encodedModel):streamGenerateContent?alt=sse"
                guard let url = URL(string: urlString) else {
                    continuation.yield(.finished(reason: .error))
                    continuation.finish(throwing: EngineFailure(kind: .providerFailure, message: "Bad Gemini URL"))
                    return
                }
                let body: Data
                do {
                    body = try Self.encodeBody(request: request)
                } catch {
                    continuation.yield(.finished(reason: .error))
                    continuation.finish(throwing: error)
                    return
                }
                // Pre-response transient retry (see AnthropicClient for rationale):
                // retry only before the server responds so output is never dup'd.
                let maxAttempts = 3
                var attempt = 0
                while true {
                    attempt += 1
                    var serverResponded = false
                    do {
                        var req = URLRequest(url: url)
                        req.httpMethod = "POST"
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                        req.httpBody = body

                        let (bytes, response) = try await session.bytes(for: req)
                        serverResponded = true
                        if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
                            throw EngineFailure(kind: .providerFailure,
                                                message: "Gemini HTTP \(http.statusCode)")
                        }

                        // Track the last per-candidate finishReason (and any
                        // promptFeedback.blockReason) so a truncated or
                        // safety-blocked response isn't reported as a clean .stop.
                        var finishReason: LLMStreamChunk.FinishReason = .stop
                        for try await event in SSEParser.stream(bytes) {
                            try Self.parseEvent(data: event.data,
                                                finishReason: &finishReason,
                                                continuation: continuation)
                        }
                        continuation.yield(.finished(reason: finishReason))
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                        return
                    } catch {
                        if !serverResponded, attempt < maxAttempts, RetryPolicy.isTransient(error) {
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

    private static func encodeBody(request: LLMRequest) throws -> Data {
        struct Body: Encodable {
            let systemInstruction: SysInstruction?
            let contents: [Content]
            let tools: [Tool]?
            let generationConfig: GenConfig
        }
        struct SysInstruction: Encodable { let parts: [Part] }
        struct Content: Encodable { let role: String; let parts: [Part] }
        struct Part: Encodable {
            let text: String?
            let functionCall: FnCall?
            let functionResponse: FnResp?
        }
        // Gemini pairs a functionResponse to its functionCall by `id` when present,
        // falling back to `name`. Carrying the id makes same-name parallel calls
        // (e.g. two web_search calls in one turn, which the worker prompt
        // encourages) disambiguate correctly instead of colliding on name alone.
        struct FnCall: Encodable { let id: String?; let name: String; let args: AnyJSON }
        struct FnResp: Encodable { let id: String?; let name: String; let response: AnyJSON }
        struct Tool: Encodable { let functionDeclarations: [FnDecl] }
        struct FnDecl: Encodable {
            let name: String
            let description: String
            let parameters: AnyJSON
        }
        struct GenConfig: Encodable {
            let temperature: Double
            let maxOutputTokens: Int?
            let stopSequences: [String]?
        }

        var systemText: String?
        var contents: [Content] = []
        for m in request.messages {
            switch m.role {
            case .system:
                systemText = (systemText.map { $0 + "\n\n" } ?? "") + m.plainText
            case .user, .assistant:
                let role = (m.role == .assistant) ? "model" : "user"
                var parts: [Part] = []
                for block in m.content {
                    switch block {
                    case .text(let s):
                        parts.append(Part(text: s, functionCall: nil, functionResponse: nil))
                    case .toolCall(let id, let name, let args):
                        let argJSON = (try? AnyJSON.parse(args)) ?? .null
                        parts.append(Part(text: nil,
                                          functionCall: FnCall(id: Self.wireCallID(id),
                                                               name: name,
                                                               args: argJSON),
                                          functionResponse: nil))
                    case .toolResult: break
                    }
                }
                if parts.isEmpty { parts = [Part(text: "", functionCall: nil, functionResponse: nil)] }
                contents.append(Content(role: role, parts: parts))
            case .tool:
                var parts: [Part] = []
                for block in m.content {
                    if case .toolResult(let callID, let name, let output) = block {
                        let json = (try? AnyJSON.parse(output)) ?? .string(output)
                        parts.append(Part(text: nil,
                                          functionCall: nil,
                                          functionResponse: FnResp(id: Self.wireCallID(callID),
                                                                   name: name,
                                                                   response: json)))
                    }
                }
                if !parts.isEmpty {
                    contents.append(Content(role: "user", parts: parts))
                }
            }
        }

        let tools = request.tools.isEmpty ? nil : [Tool(functionDeclarations: request.tools.map {
            FnDecl(name: $0.name,
                   description: $0.description,
                   parameters: (try? AnyJSON.parse($0.parametersJSONSchema)) ?? .null)
        })]

        let body = Body(
            systemInstruction: systemText.map { SysInstruction(parts: [Part(text: $0, functionCall: nil, functionResponse: nil)]) },
            contents: contents,
            tools: tools,
            generationConfig: GenConfig(
                temperature: request.temperature,
                maxOutputTokens: request.maxTokens,
                stopSequences: request.stopSequences.isEmpty ? nil : request.stopSequences
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(body)
    }

    private static func parseEvent(data: String,
                                   finishReason: inout LLMStreamChunk.FinishReason,
                                   continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation) throws {
        guard let bytes = data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }

        if let candidates = obj["candidates"] as? [[String: Any]] {
            for c in candidates {
                if let content = c["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]] {
                    for p in parts {
                        if let text = p["text"] as? String, !text.isEmpty {
                            continuation.yield(.text(text))
                        }
                        if let fn = p["functionCall"] as? [String: Any],
                           let name = fn["name"] as? String {
                            let argsJSON: String
                            if let args = fn["args"] {
                                let data = try JSONSerialization.data(withJSONObject: args)
                                argsJSON = String(decoding: data, as: UTF8.self)
                            } else {
                                argsJSON = "{}"
                            }
                            // Preserve any Gemini-supplied call id in the wire id so
                            // the functionResponse we send back can echo the SAME id
                            // and pair correctly on same-name parallel calls. When
                            // Gemini omits an id, mint a synthetic one as before.
                            let geminiID = (fn["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                            let id = geminiID.map { "gemini-id-\($0)" }
                                ?? "gemini-fn-\(name)-\(UUID().uuidString.prefix(6))"
                            continuation.yield(.toolCallStart(id: id, name: name))
                            continuation.yield(.toolCallArgumentsDelta(id: id, delta: argsJSON))
                            continuation.yield(.toolCallEnd(id: id))
                        }
                    }
                }
                // Map the per-candidate finishReason to the LLM-layer reason. The
                // last non-empty reason in the stream wins. STOP and the streaming
                // "still generating" cases stay .stop; truncation/safety surface so
                // the engine can detect an incomplete answer.
                if let reason = c["finishReason"] as? String, !reason.isEmpty {
                    finishReason = mapFinishReason(reason)
                }
            }
        }
        // No candidates but a prompt-level block (safety/recitation on the input)
        // is itself a non-stop terminal condition; surface it as a content filter.
        if (obj["candidates"] as? [[String: Any]])?.isEmpty ?? true,
           let feedback = obj["promptFeedback"] as? [String: Any],
           let block = feedback["blockReason"] as? String, !block.isEmpty {
            finishReason = .contentFilter
        }
        if let usage = obj["usageMetadata"] as? [String: Any] {
            let p = usage["promptTokenCount"] as? Int ?? 0
            let c = usage["candidatesTokenCount"] as? Int ?? 0
            continuation.yield(.usage(promptTokens: p, completionTokens: c))
        }
    }

    /// Translate a Gemini candidate `finishReason` to the unified finish reason.
    /// MAX_TOKENS → .length; SAFETY/RECITATION/BLOCKLIST/PROHIBITED_CONTENT/SPII →
    /// .contentFilter; MALFORMED_FUNCTION_CALL/OTHER/unknown → .stop (treated as a
    /// normal end so the worker still consumes whatever text/tool calls arrived).
    private static func mapFinishReason(_ raw: String) -> LLMStreamChunk.FinishReason {
        switch raw {
        case "MAX_TOKENS": return .length
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII":
            return .contentFilter
        default: return .stop
        }
    }

    /// Recover the original Gemini call id from the wire id we synthesized in
    /// `parseEvent`. Only ids that Gemini itself supplied (encoded with the
    /// `gemini-id-` prefix) are sent back as `functionCall.id`/`functionResponse.id`;
    /// purely synthetic ids return nil so we don't send Gemini an id it never issued.
    private static func wireCallID(_ id: String) -> String? {
        let prefix = "gemini-id-"
        guard id.hasPrefix(prefix) else { return nil }
        let recovered = String(id.dropFirst(prefix.count))
        return recovered.isEmpty ? nil : recovered
    }
}
