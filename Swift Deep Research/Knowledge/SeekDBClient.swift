import Foundation

/// HTTP client for the local pyseekdb sidecar (`sidecar/seekdb_sidecar.py`).
///
/// `SidecarSupervisor` auto-launches the sidecar at app startup (and bootstraps
/// a private Python virtualenv with the dependencies if they're missing), so
/// users don't start it manually. If it still isn't reachable the client
/// surfaces a clear `SeekDBError.unreachable` instead of hanging the UI;
/// callers such as `KnowledgeBaseTool` then ask the supervisor to recover it.
public actor SeekDBClient {
    public let host: URL
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public init(host: URL = URL(string: "http://127.0.0.1:9100")!,
                session: URLSession = HTTPClientCommon.defaultSession(timeout: 30)) {
        self.host = host
        self.session = session
    }

    // MARK: - Health

    public func health() async throws -> Health {
        try await request("/health", method: "GET")
    }

    // MARK: - Documents

    public func listDocuments() async throws -> [Document] {
        try await request("/documents", method: "GET")
    }

    public func upsert(title: String,
                       text: String,
                       metadata: [String: String]? = nil,
                       id: String? = nil) async throws -> Document {
        struct Body: Encodable {
            let id: String?
            let title: String
            let text: String
            let metadata: [String: String]?
        }
        let body = Body(id: id, title: title, text: text, metadata: metadata)
        return try await request("/documents", method: "POST", body: body)
    }

    public func delete(id: String) async throws {
        let _: AcknowledgedResponse = try await request("/documents/\(id)", method: "DELETE")
    }

    public func reset() async throws {
        let _: AcknowledgedResponse = try await request("/reset", method: "POST")
    }

    public func query(_ query: String, k: Int = 6) async throws -> [QueryHit] {
        struct Body: Encodable { let query: String; let k: Int }
        return try await request("/query", method: "POST", body: Body(query: query, k: k))
    }

    // MARK: - Wire types

    public struct Health: Decodable, Sendable {
        public let ok: Bool
        public let mode: String?
        public let database: String?
        public let collection: String?
        public let documents: Int?
    }

    public struct Document: Decodable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let chunks: Int
        public let added_at: String?
        public let source: String?
    }

    public struct QueryHit: Decodable, Sendable, Identifiable {
        public let id: String
        public let text: String
        public let score: Double?
        public let metadata: [String: AnyCodableValue]?

        public var docID: String {
            if let m = metadata?["doc_id"]?.stringValue { return m }
            return String(id.split(separator: "::").first ?? Substring(id))
        }
        public var title: String {
            metadata?["title"]?.stringValue ?? id
        }
    }

    private struct AcknowledgedResponse: Decodable { }

    // MARK: - Errors

    public enum SeekDBError: Error, LocalizedError, Sendable {
        case unreachable(URL)
        case httpStatus(Int, String)
        case decode(String)

        public var errorDescription: String? {
            switch self {
            case .unreachable(let url):
                return "Sidecar at \(url.absoluteString) is unreachable. Start it with `python3 sidecar/seekdb_sidecar.py`."
            case .httpStatus(let code, let body):
                return "Sidecar returned HTTP \(code): \(body.prefix(200))"
            case .decode(let m):
                return "Sidecar response decode failed: \(m)"
            }
        }
    }

    // MARK: - Request plumbing

    private func request<R: Decodable>(_ path: String,
                                       method: String,
                                       body: (any Encodable)? = nil) async throws -> R {
        guard let url = URL(string: path, relativeTo: host) else {
            throw SeekDBError.unreachable(host)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try encoder.encode(AnyEncodable(body))
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw SeekDBError.unreachable(host)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SeekDBError.unreachable(host)
        }
        guard (200..<300) ~= http.statusCode else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw SeekDBError.httpStatus(http.statusCode, text)
        }
        if R.self == AcknowledgedResponse.self {
            return AcknowledgedResponse() as! R
        }
        do {
            return try decoder.decode(R.self, from: data)
        } catch {
            throw SeekDBError.decode(error.localizedDescription)
        }
    }
}

/// Type-erased wrapper so `request` can accept any Encodable body.
private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

/// Loose Decodable for metadata fields whose values can be string / int / bool.
public enum AnyCodableValue: Decodable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        self = .null
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .bool(let b): String(b)
        case .null: nil
        }
    }
}
