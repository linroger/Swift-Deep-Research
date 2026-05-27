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
                session: URLSession = HTTPClientCommon.defaultSession(timeout: 120)) {
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
                do {
                    guard !apiKey.isEmpty else {
                        throw EngineFailure(kind: .configurationMissing,
                                            message: "Gemini API key not set.")
                    }
                    let modelID = request.model ?? model
                    let urlString = baseURL.absoluteString
                        + "/v1beta/models/\(modelID):streamGenerateContent?alt=sse&key=\(apiKey)"
                    guard let url = URL(string: urlString) else {
                        throw EngineFailure(kind: .providerFailure, message: "Bad Gemini URL")
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try Self.encodeBody(request: request)

                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
                        throw EngineFailure(kind: .providerFailure,
                                            message: "Gemini HTTP \(http.statusCode)")
                    }

                    for try await event in SSEParser.stream(bytes) {
                        try Self.parseEvent(data: event.data, continuation: continuation)
                    }
                    continuation.yield(.finished(reason: .stop))
                    continuation.finish()
                } catch {
                    continuation.yield(.finished(reason: .error))
                    continuation.finish(throwing: error)
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
        struct FnCall: Encodable { let name: String; let args: AnyJSON }
        struct FnResp: Encodable { let name: String; let response: AnyJSON }
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
                    case .toolCall(_, let name, let args):
                        let argJSON = (try? AnyJSON.parse(args)) ?? .null
                        parts.append(Part(text: nil,
                                          functionCall: FnCall(name: name, args: argJSON),
                                          functionResponse: nil))
                    case .toolResult: break
                    }
                }
                if parts.isEmpty { parts = [Part(text: "", functionCall: nil, functionResponse: nil)] }
                contents.append(Content(role: role, parts: parts))
            case .tool:
                var parts: [Part] = []
                for block in m.content {
                    if case .toolResult(_, let name, let output) = block {
                        let json = (try? AnyJSON.parse(output)) ?? .string(output)
                        parts.append(Part(text: nil,
                                          functionCall: nil,
                                          functionResponse: FnResp(name: name, response: json)))
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
                            let id = "gemini-fn-\(name)-\(UUID().uuidString.prefix(6))"
                            continuation.yield(.toolCallStart(id: id, name: name))
                            continuation.yield(.toolCallArgumentsDelta(id: id, delta: argsJSON))
                            continuation.yield(.toolCallEnd(id: id))
                        }
                    }
                }
            }
        }
        if let usage = obj["usageMetadata"] as? [String: Any] {
            let p = usage["promptTokenCount"] as? Int ?? 0
            let c = usage["candidatesTokenCount"] as? Int ?? 0
            continuation.yield(.usage(promptTokens: p, completionTokens: c))
        }
    }
}
