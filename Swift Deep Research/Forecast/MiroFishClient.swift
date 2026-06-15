import Foundation

// MARK: - MiroFishClient
//
// HTTP client for the MiroFish prediction backend (Flask, default :5001). MiroFish
// already exposes the unified DeerFlow→ontology→Graphiti-graph→OASIS-simulation→report
// pipeline at `POST /api/research/run`; this client drives it and reads every stage
// back out so the native macOS UI can render the whole forecast.
//
// `MiroFishSupervisor` auto-launches the backend (mirroring `SidecarSupervisor`),
// so callers don't start it manually. When it's unreachable the client surfaces a
// clear `MiroFishError.unreachable` rather than hanging the UI.
//
// Every MiroFish JSON response is enveloped as `{"success": Bool, "data": …}` or
// `{"success": false, "error": "…"}` — except `GET /health`, which is bare. The
// generic `request` here unwraps the envelope; `health()` is handled specially.
//
// Wire structs use the exact snake_case JSON field names as Swift property names
// (no key-decoding strategy), matching the codebase convention. Timestamps stay
// `String` — MiroFish mixes tz-aware and naive ISO-8601 across endpoints, so we
// never assume a single date format.

public actor MiroFishClient {
    public let host: URL
    private let session: URLSession
    private let decoder = JSONDecoder()

    /// Per-request inactivity timeout for endpoints that block server-side before
    /// emitting a response (pipeline start/resume do synchronous setup before
    /// returning a pipeline_id; a large graph can take a while to serialize). The
    /// short `defaultSession(timeout: 60)` is kept for quick status/polling calls.
    private static let longRunningTimeout: TimeInterval = 300

    public init(host: URL = URL(string: "http://127.0.0.1:5001")!,
                session: URLSession = HTTPClientCommon.defaultSession(timeout: 60)) {
        self.host = host
        self.session = session
    }

    // MARK: - Health / settings

    /// Bare `GET /health` (no envelope). Throws `unreachable` on any transport error.
    public func health() async throws -> MFHealth {
        try await requestRaw("/health", method: "GET")
    }

    public func providerInfo() async throws -> MFProviderInfo {
        try await request("/api/settings/llm", method: "GET")
    }

    /// Switch the backend's LLM provider at runtime (affects newly started
    /// pipelines only). `apiKey` is required by providers whose `needs_key` is
    /// true unless the backend already holds one for that provider.
    public func setProvider(_ provider: String,
                            apiKey: String? = nil,
                            baseURL: String? = nil,
                            model: String? = nil) async throws -> MFProviderInfo {
        struct Body: Encodable {
            let provider: String
            let api_key: String?
            let base_url: String?
            let model: String?
        }
        return try await request("/api/settings/llm", method: "POST",
                                 body: Body(provider: provider, api_key: apiKey,
                                            base_url: baseURL, model: model))
    }

    // MARK: - Pipeline

    /// Cheap pre-run readiness check (offline checks only — no pipeline started).
    /// Mirrors the gate inside `POST /run`, so a misconfigured provider / invalid
    /// GRAPH_BACKEND / placeholder credential is caught BEFORE any research spend.
    /// `mode` is the forecast mode (`full` | `research_only`).
    public func preflight(mode: String) async throws -> MFPreflight {
        try await request("/api/research/preflight?mode=\(mode)", method: "GET")
    }

    public func runPipeline(prompt: String,
                            mode: String,
                            depth: String,
                            projectName: String?,
                            maxRounds: Int?) async throws -> MFRunResponse {
        struct Body: Encodable {
            let prompt: String
            let mode: String
            let depth: String
            let project_name: String?
            let max_rounds: Int?
        }
        let body = Body(prompt: prompt, mode: mode, depth: depth,
                        project_name: projectName, max_rounds: maxRounds)
        // The backend can do synchronous setup before returning a pipeline_id; the
        // 60s default would spuriously fail the start (and risk orphaning a started
        // pipeline the app never recorded). Give it the long-running budget.
        return try await request("/api/research/run", method: "POST", body: body,
                                 timeout: Self.longRunningTimeout)
    }

    public func pipelineStatus(_ pipelineID: String) async throws -> MFPipelineState {
        try await request("/api/research/status/\(pipelineID)", method: "GET")
    }

    public func dossier(_ pipelineID: String) async throws -> MFDossier {
        try await request("/api/research/\(pipelineID)/dossier", method: "GET")
    }

    public func researchProgress(_ pipelineID: String, lines: Int = 200) async throws -> MFResearchProgress {
        try await request("/api/research/\(pipelineID)/progress?lines=\(lines)", method: "GET")
    }

    public func listPipelines() async throws -> [MFPipelineSummary] {
        let wrap: MFPipelineList = try await request("/api/research/list", method: "GET")
        return wrap.pipelines
    }

    /// Cancel an in-flight pipeline. The backend kills the DeerFlow/OASIS child
    /// process groups, so this is the only way to actually stop token spend —
    /// dropping the poll loop alone leaves the pipeline running server-side.
    /// 404 (unknown) and 409 (already finished) are swallowed: in both cases the
    /// pipeline is not running, which is what the caller wanted.
    public func cancelPipeline(_ pipelineID: String) async throws {
        struct CancelResult: Decodable, Sendable { let status: String? }
        do {
            let _: CancelResult = try await request("/api/research/\(pipelineID)/cancel", method: "POST")
        } catch MiroFishError.httpStatus(let code, _) where code == 404 || code == 409 {
            return
        }
    }

    /// Resume a failed/cancelled pipeline. The backend reuses completed stage
    /// artifacts (research report, graph, …) so this skips the expensive re-runs.
    public func resumePipeline(_ pipelineID: String) async throws -> MFRunResponse {
        // Like /run, the backend may block on synchronous stage setup before
        // responding — use the long-running timeout, not the 60s default.
        try await request("/api/research/\(pipelineID)/resume", method: "POST",
                          timeout: Self.longRunningTimeout)
    }

    /// Delete a terminal pipeline record (and its handoff artifacts) on the backend.
    public func deletePipeline(_ pipelineID: String) async throws {
        struct DeleteResult: Decodable, Sendable { let status: String? }
        do {
            let _: DeleteResult = try await request("/api/research/\(pipelineID)", method: "DELETE")
        } catch MiroFishError.httpStatus(let code, _) where code == 404 {
            return  // already gone
        }
    }

    // MARK: - Project / ontology

    public func project(_ projectID: String) async throws -> MFProject {
        try await request("/api/graph/project/\(projectID)", method: "GET")
    }

    // MARK: - Knowledge graph

    public func graphData(_ graphID: String) async throws -> MFGraphData {
        // A large knowledge graph can take a while to serialize server-side; allow
        // more than the 60s polling default so a big graph fetch doesn't spuriously
        // time out and get treated as a transient transport failure.
        try await request("/api/graph/data/\(graphID)", method: "GET",
                          timeout: Self.longRunningTimeout)
    }

    // MARK: - Simulation

    /// Lightweight poll. Returns an idle stub when the run hasn't started.
    public func runStatus(_ simulationID: String) async throws -> MFRunState {
        try await request("/api/simulation/\(simulationID)/run-status", method: "GET")
    }

    /// Run status enriched with recent/all actions (heavier).
    public func runStatusDetail(_ simulationID: String, platform: String? = nil) async throws -> MFRunState {
        var path = "/api/simulation/\(simulationID)/run-status/detail"
        if let platform { path += "?platform=\(platform)" }
        return try await request(path, method: "GET")
    }

    public func timeline(_ simulationID: String) async throws -> MFTimeline {
        try await request("/api/simulation/\(simulationID)/timeline", method: "GET")
    }

    public func agentStats(_ simulationID: String) async throws -> MFAgentStats {
        try await request("/api/simulation/\(simulationID)/agent-stats", method: "GET")
    }

    // MARK: - Report

    public func report(_ reportID: String) async throws -> MFReport {
        try await request("/api/report/\(reportID)", method: "GET")
    }

    public func reportProgress(_ reportID: String) async throws -> MFReportProgress {
        try await request("/api/report/\(reportID)/progress", method: "GET")
    }

    /// Machine-readable structured forecast (scenarios + probabilities + drivers)
    /// for a finished report, via the stable `/api/v1` surface. Requires the
    /// backend to run with `REPORT_STRUCTURED_FORECAST=true` and `API_V1_ENABLED=true`
    /// (the app seeds both into `.env`); otherwise the backend answers 409/404 and
    /// the caller treats the absence as "no structured forecast". (E3-forecast-2)
    public func structuredForecast(reportID: String) async throws -> MFForecastEnvelope {
        try await request("/api/v1/forecast/\(reportID)", method: "GET")
    }

    /// Incremental ReAct agent log. Poll with `fromLine = previous total_lines`.
    public func reportAgentLog(_ reportID: String, fromLine: Int = 0) async throws -> MFAgentLog {
        try await request("/api/report/\(reportID)/agent-log?from_line=\(fromLine)", method: "GET")
    }

    /// Ask the report agent a follow-up question. The agent runs a short ReAct
    /// loop with graph-retrieval tools, so responses can take a couple of minutes
    /// — the request gets a generous per-call timeout instead of the default.
    public func reportChat(simulationID: String,
                           message: String,
                           history: [MFChatTurn]) async throws -> MFChatReply {
        struct Body: Encodable {
            let simulation_id: String
            let message: String
            let chat_history: [MFChatTurn]
        }
        return try await request("/api/report/chat", method: "POST",
                                 body: Body(simulation_id: simulationID,
                                            message: message,
                                            chat_history: history),
                                 timeout: 300)
    }

    // MARK: - Request plumbing

    /// Unwraps the `{success, data}` envelope and returns the decoded `data`.
    private func request<R: Decodable & Sendable>(_ path: String,
                                                  method: String,
                                                  body: (any Encodable & Sendable)? = nil,
                                                  timeout: TimeInterval? = nil) async throws -> R {
        let data = try await rawData(path, method: method, body: body, timeout: timeout)
        let envelope: MFEnvelope<R>
        do {
            envelope = try decoder.decode(MFEnvelope<R>.self, from: data)
        } catch {
            throw MiroFishError.decode("\(path): \(error.localizedDescription)")
        }
        guard envelope.success else {
            throw MiroFishError.api(envelope.error ?? "MiroFish reported failure", path: path)
        }
        guard let payload = envelope.data else {
            throw MiroFishError.decode("\(path): success but missing data")
        }
        return payload
    }

    /// For bare (un-enveloped) responses like `/health`.
    private func requestRaw<R: Decodable & Sendable>(_ path: String,
                                                     method: String) async throws -> R {
        let data = try await rawData(path, method: method, body: nil)
        do {
            return try decoder.decode(R.self, from: data)
        } catch {
            throw MiroFishError.decode("\(path): \(error.localizedDescription)")
        }
    }

    private func rawData(_ path: String,
                         method: String,
                         body: (any Encodable & Sendable)?,
                         timeout: TimeInterval? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: host) else {
            throw MiroFishError.unreachable(host)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(MFAnyEncodable(body))
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw MiroFishError.unreachable(host)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MiroFishError.unreachable(host)
        }
        guard (200..<300) ~= http.statusCode else {
            // MiroFish frequently returns 4xx/5xx with a JSON `{"error": …}` body.
            let message = Self.extractError(from: data) ?? String(data: data, encoding: .utf8)?.prefix(300).description ?? ""
            throw MiroFishError.httpStatus(http.statusCode, message)
        }
        return data
    }

    private static func extractError(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["error"] as? String
    }
}

// MARK: - Errors

public enum MiroFishError: Error, LocalizedError, Sendable {
    case unreachable(URL)
    case httpStatus(Int, String)
    case api(String, path: String)
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let url):
            return "MiroFish backend at \(url.absoluteString) is unreachable. It may still be starting, or the backend folder/venv isn't set up."
        case .httpStatus(let code, let body):
            return "MiroFish returned HTTP \(code): \(body.prefix(240))"
        case .api(let message, _):
            return message
        case .decode(let m):
            return "Could not read MiroFish response: \(m)"
        }
    }

    /// Heuristic: is this worth retrying transparently (transient transport or 5xx)?
    public var isTransient: Bool {
        switch self {
        case .unreachable: return true
        case .httpStatus(let code, _): return code == 429 || (500...599).contains(code)
        default: return false
        }
    }
}

/// Type-erased Encodable so `rawData` can take any body. Mirrors SeekDBClient's helper.
private struct MFAnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

// MARK: - Envelope

public struct MFEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    public let success: Bool
    public let data: T?
    public let error: String?
}

// MARK: - Health / settings wire types

public struct MFHealth: Decodable, Sendable {
    public let status: String
    public let service: String?
}

public struct MFProviderInfo: Decodable, Sendable {
    public let current: String?
    public let deerflow_model: String?
    public let has_api_key: Bool?
    public let base_url: String?
    public let model_name: String?
    public let providers: [MFProvider]?
}

public struct MFProvider: Decodable, Sendable, Identifiable {
    public let id: String
    public let label: String?
    public let needs_key: Bool?
}

// MARK: - Pipeline wire types

/// `GET /api/research/preflight` result (default format): a fast readiness gate.
public struct MFPreflight: Decodable, Sendable {
    public let ready: Bool
    public let errors: [String]
    public let mode: String?
}

public struct MFRunResponse: Decodable, Sendable {
    public let pipeline_id: String
    public let task_id: String?
    public let mode: String?
    public let status: String?
    /// True on `POST /<id>/resume` responses.
    public let resumed: Bool?
}

public struct MFStageState: Decodable, Sendable, Identifiable, Equatable {
    public let name: String
    public let status: String
    public let progress: Int
    public let message: String?
    public let started_at: String?
    public let finished_at: String?
    public let error: String?
    public var id: String { name }
}

public struct MFPipelineOptions: Decodable, Sendable, Equatable {
    public let project_name: String?
    public let depth: String?
    public let max_rounds: Int?
}

public struct MFPipelineState: Decodable, Sendable, Equatable {
    public let pipeline_id: String
    public let prompt: String
    public let mode: String
    public let status: String
    public let global_progress: Int
    public let current_stage: String
    public let task_id: String?
    public let project_id: String?
    public let graph_id: String?
    public let simulation_id: String?
    public let report_id: String?
    public let handoff_dir: String?
    public let error: String?
    public let created_at: String?
    public let updated_at: String?
    public let options: MFPipelineOptions?
    public let stages: [String: MFStageState]
}

public struct MFPipelineSummary: Decodable, Sendable, Identifiable {
    public let pipeline_id: String
    public let status: String
    public let prompt: String
    public let global_progress: Int
    public let created_at: String?
    public let report_id: String?
    public var id: String { pipeline_id }
}

struct MFPipelineList: Decodable, Sendable {
    let pipelines: [MFPipelineSummary]
}

public struct MFResearchProgress: Decodable, Sendable {
    public let lines: [String]
    public let total: Int?
}

// MARK: - Dossier

/// `actors`/`sources` are documented as "arbitrary JSON" — decode them as `AnyJSON`
/// so a shape change never breaks the dossier fetch. Strongly-typed accessors below
/// pull out the actor table when it matches the expected shape.
public struct MFDossier: Decodable, Sendable {
    public let report: String?
    public let has_report: Bool?
    public let actors: AnyJSON?
    public let sources: AnyJSON?

    /// Best-effort extraction of `{actors: [{name,type,role,stance,...}], hot_topics: []}`.
    public var actorList: [MFActor] {
        guard case .object(let root)? = actors,
              case .array(let arr)? = root["actors"] else { return [] }
        return arr.enumerated().compactMap { index, item in
            guard case .object(let o) = item else { return nil }
            func str(_ k: String) -> String? {
                if case .string(let s)? = o[k] { return s }
                return nil
            }
            return MFActor(index: index,
                           name: str("name"),
                           type: str("type"),
                           role: str("role"),
                           stance: str("stance"),
                           influence: str("influence"))
        }
    }

    public var hotTopics: [String] {
        guard case .object(let root)? = actors,
              case .array(let arr)? = root["hot_topics"] else { return [] }
        return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    /// Cited sources as flat (title, url) rows when `sources.json` is shaped that way.
    public var sourceList: [MFSourceRef] {
        func rows(from arr: [AnyJSON]) -> [MFSourceRef] {
            arr.enumerated().compactMap { index, item in
                guard case .object(let o) = item else {
                    if case .string(let s) = item { return MFSourceRef(index: index, title: s, url: s) }
                    return nil
                }
                func str(_ keys: [String]) -> String? {
                    for k in keys { if case .string(let s)? = o[k] { return s } }
                    return nil
                }
                let url = str(["url", "link", "href"])
                let title = str(["title", "name"]) ?? url
                guard title != nil || url != nil else { return nil }
                return MFSourceRef(index: index, title: title ?? url ?? "", url: url ?? "")
            }
        }
        switch sources {
        case .array(let arr)?: return rows(from: arr)
        case .object(let root)?:
            if case .array(let arr)? = root["sources"] { return rows(from: arr) }
            return []
        default: return []
        }
    }
}

public struct MFActor: Sendable, Identifiable {
    public let index: Int
    public let name: String?
    public let type: String?
    public let role: String?
    public let stance: String?
    public let influence: String?
    public var id: Int { index }
    public var displayName: String { name ?? "Actor \(index + 1)" }
}

public struct MFSourceRef: Sendable, Identifiable {
    public let index: Int
    public let title: String
    public let url: String
    public var id: Int { index }
}

// MARK: - Project / ontology wire types

public struct MFProject: Decodable, Sendable {
    public let project_id: String?
    public let name: String?
    public let status: String?
    public let ontology: MFOntology?
    public let analysis_summary: String?
    public let graph_id: String?
    public let total_text_length: Int?
}

public struct MFOntology: Decodable, Sendable {
    public let entity_types: [MFOntologyType]?
    public let edge_types: [MFOntologyType]?
}

public struct MFOntologyType: Decodable, Sendable, Identifiable {
    public let name: String
    public let description: String?
    public var id: String { name }
}

// MARK: - Knowledge-graph wire types

public struct MFGraphData: Decodable, Sendable {
    public let graph_id: String?
    public let nodes: [MFNode]
    public let edges: [MFEdge]
    public let node_count: Int?
    public let edge_count: Int?
}

public struct MFNode: Decodable, Sendable, Identifiable {
    public let uuid: String
    public let name: String?
    public let labels: [String]?
    public let summary: String?
    public let created_at: String?
    public var id: String { uuid }

    /// Entity type = first label that isn't a generic base label.
    public var entityType: String {
        (labels ?? []).first(where: { $0 != "Entity" && $0 != "Node" }) ?? "Entity"
    }
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return String(uuid.prefix(8))
    }
}

public struct MFEdge: Decodable, Sendable, Identifiable {
    public let uuid: String
    public let name: String?
    public let fact: String?
    public let fact_type: String?
    public let source_node_uuid: String
    public let target_node_uuid: String
    public let source_node_name: String?
    public let target_node_name: String?
    public var id: String { uuid }
    public var relationship: String { fact_type ?? name ?? "" }
}

// MARK: - Simulation wire types

/// Serves both `/run-status` and `/run-status/detail`: the action/detail fields are
/// optional, so the lightweight poll decodes them as nil.
public struct MFRunState: Decodable, Sendable {
    public let simulation_id: String?
    public let runner_status: String?
    public let current_round: Int?
    public let total_rounds: Int?
    public let simulated_hours: Int?
    public let total_simulation_hours: Int?
    public let progress_percent: Double?
    public let twitter_current_round: Int?
    public let reddit_current_round: Int?
    public let twitter_running: Bool?
    public let reddit_running: Bool?
    public let twitter_completed: Bool?
    public let reddit_completed: Bool?
    public let twitter_actions_count: Int?
    public let reddit_actions_count: Int?
    public let total_actions_count: Int?
    public let started_at: String?
    public let error: String?

    // Only present on /run-status/detail:
    public let recent_actions: [MFAgentAction]?
    public let all_actions: [MFAgentAction]?
    public let rounds_count: Int?
}

public struct MFAgentAction: Decodable, Sendable, Identifiable {
    public let round_num: Int?
    public let timestamp: String?
    public let platform: String?
    public let agent_id: Int?
    public let agent_name: String?
    public let action_type: String?
    public let result: String?
    public let success: Bool?

    public var id: String {
        "\(platform ?? "")|\(agent_id ?? -1)|\(round_num ?? -1)|\(action_type ?? "")|\(timestamp ?? "")"
    }
}

public struct MFTimeline: Decodable, Sendable {
    public let rounds_count: Int?
    public let timeline: [MFTimelineEntry]
}

public struct MFTimelineEntry: Decodable, Sendable, Identifiable {
    public let round_num: Int
    public let twitter_actions: Int?
    public let reddit_actions: Int?
    public let total_actions: Int?
    public let active_agents_count: Int?
    public var id: Int { round_num }
}

public struct MFAgentStats: Decodable, Sendable {
    public let agents_count: Int?
    public let stats: [MFAgentStat]
}

public struct MFAgentStat: Decodable, Sendable, Identifiable {
    public let agent_id: Int
    public let agent_name: String?
    public let total_actions: Int?
    public let twitter_actions: Int?
    public let reddit_actions: Int?
    public var id: Int { agent_id }
}

// MARK: - Report wire types

public struct MFReport: Decodable, Sendable {
    public let report_id: String?
    public let simulation_id: String?
    public let graph_id: String?
    public let simulation_requirement: String?
    public let status: String?
    public let outline: MFOutline?
    public let markdown_content: String?
    public let created_at: String?
    public let completed_at: String?
    public let error: String?
}

public struct MFOutline: Decodable, Sendable {
    public let title: String?
    public let summary: String?
    public let sections: [MFOutlineSection]?
}

public struct MFOutlineSection: Decodable, Sendable, Identifiable {
    public let title: String?
    public let content: String?
    public var id: String { title ?? UUID().uuidString }
}

// MARK: - Structured forecast wire types (/api/v1/forecast)

/// Envelope returned by `GET /api/v1/forecast/<report_id>`: the report ids plus
/// the structured forecast object (nil when the report has no structured forecast).
public struct MFForecastEnvelope: Decodable, Sendable {
    public let report_id: String?
    public let simulation_id: String?
    public let forecast: MFForecast?
}

/// A calibrated, machine-readable forecast: a probability distribution over named
/// outcome scenarios, an overall confidence, and a time horizon.
public struct MFForecast: Decodable, Sendable {
    public let horizon: String?
    public let confidence: String?      // low | medium | high
    public let scenarios: [MFScenario]

    /// Scenarios sorted most-likely first, for display.
    public var rankedScenarios: [MFScenario] {
        scenarios.sorted { $0.probability > $1.probability }
    }
}

public struct MFScenario: Decodable, Sendable, Identifiable {
    public let name: String
    public let probability: Double      // 0.0–1.0 (normalized server-side to ≈1 total)
    public let summary: String?
    public let key_drivers: [String]?
    public var id: String { name }
    /// Probability as a 0–100 percentage for labels.
    public var percent: Int { Int((probability * 100).rounded()) }
}

public struct MFReportProgress: Decodable, Sendable {
    public let status: String?
    public let progress: Int?
    public let message: String?
    public let current_section: String?
    public let completed_sections: [String]?
    public let updated_at: String?
}

/// One prior exchange sent back to `POST /api/report/chat` as context.
public struct MFChatTurn: Codable, Sendable {
    public let role: String       // "user" | "assistant"
    public let content: String
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// Reply from the report agent. `tool_calls`/`sources` are free-form JSON whose
/// shape varies by tool, so they stay `AnyJSON` and the UI summarises them.
public struct MFChatReply: Decodable, Sendable {
    public let response: String?
    public let tool_calls: AnyJSON?
    public let sources: AnyJSON?

    /// Names of the retrieval tools the agent invoked, when reported.
    public var toolNames: [String] {
        guard case .array(let arr)? = tool_calls else { return [] }
        return arr.compactMap {
            if case .object(let o) = $0 {
                if case .string(let name)? = o["tool_name"] { return name }
                if case .string(let name)? = o["name"] { return name }
            }
            if case .string(let s) = $0 { return s }
            return nil
        }
    }
}

public struct MFAgentLog: Decodable, Sendable {
    public let logs: [MFAgentLogEntry]
    public let total_lines: Int?
    public let from_line: Int?
    public let has_more: Bool?
}

public struct MFAgentLogEntry: Decodable, Sendable, Identifiable {
    public let timestamp: String?
    public let elapsed_seconds: Double?
    public let action: String?
    public let stage: String?
    public let section_title: String?
    public let section_index: Int?
    // `details` is action-specific free-form JSON.
    public let details: AnyJSON?

    public var id: String {
        "\(timestamp ?? "")|\(action ?? "")|\(section_index.map(String.init) ?? "")"
    }

    /// A short human line for the live console.
    public var summary: String {
        let a = action ?? "log"
        if case .object(let o)? = details {
            if case .string(let tool)? = o["tool_name"] { return "\(a): \(tool)" }
            if case .string(let msg)? = o["message"] { return "\(a): \(msg)" }
        }
        if let s = section_title, !s.isEmpty { return "\(a): \(s)" }
        return a
    }
}
