import Foundation
import Observation
import SwiftData

/// One in-flight (or restored) forecast pipeline. The MiroFish backend runs the
/// whole DeerFlow→graph→simulation→report chain in one background job; this
/// controller drives `POST /api/research/run`, polls `/status`, and fans out to
/// the graph / simulation / report endpoints so the UI can render every stage
/// live. Analogous to `LiveSession` for the research workspace.
@MainActor
@Observable
public final class ForecastRun: Identifiable {
    public let id = UUID()
    public let prompt: String
    public let mode: Mode
    public let depth: String
    public let maxRounds: Int?
    public let startedAt: Date = .now

    public enum Mode: String, Sendable, CaseIterable {
        case full
        case research_only
        public var label: String { self == .full ? "Full forecast" : "Research only" }
    }
    public enum Phase: String, Sendable {
        case idle, starting, running, completed, failed, cancelled
        public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
        public var isActive: Bool { self == .starting || self == .running }
    }

    // Overall
    public var phase: Phase = .idle
    public var pipelineID: String?
    public var globalProgress: Int = 0
    public var currentStage: String = ""
    public var stages: [ForecastStage]
    public var errorMessage: String?
    /// True when this run was loaded from a stored record (read-only snapshot).
    public private(set) var isRestored: Bool = false

    // Stage: research
    public var researchLines: [String] = []
    public var dossier: MFDossier?

    // Stage: ontology
    public var ontology: MFOntology?

    // Stage: knowledge graph
    public var graph: ForecastGraph?
    public var graphID: String?

    // Stage: simulation
    public var runState: MFRunState?
    public var recentActions: [MFAgentAction] = []
    public var timeline: [MFTimelineEntry] = []
    public var simulationID: String?

    // Stage: report
    public var report: MFReport?
    public var reportProgress: MFReportProgress?
    public var agentLog: [MFAgentLogEntry] = []
    public var reportID: String?

    // Follow-up chat with the report agent (needs a finished simulation).
    public var chatMessages: [ChatMessage] = []
    public var chatBusy: Bool = false
    public var chatError: String?

    public struct ChatMessage: Sendable, Identifiable {
        public let id = UUID()
        public let role: Role
        public let text: String
        public let toolNames: [String]
        public enum Role: String, Sendable { case user, assistant }
    }

    private let client: MiroFishClient
    private let store: ResearchStore
    private var record: ForecastRecord?
    private var pollTask: Task<Void, Never>?
    private var agentLogCursor = 0
    private var lastPersistedReportLength = 0

    public init(prompt: String,
                mode: Mode,
                depth: String,
                maxRounds: Int?,
                client: MiroFishClient,
                store: ResearchStore) {
        self.prompt = prompt
        self.mode = mode
        self.depth = depth
        self.maxRounds = maxRounds
        self.client = client
        self.store = store
        let kinds: [ForecastStageKind] = (mode == .research_only) ? [.research] : ForecastStageKind.allCases
        self.stages = kinds.map { ForecastStage(kind: $0) }
    }

    // MARK: - Lifecycle

    public func start() {
        guard phase == .idle else { return }
        phase = .starting
        pollTask = Task { @MainActor [weak self] in await self?.launch() }
    }

    /// Stop following this run locally without touching the backend pipeline —
    /// used when the UI switches to another forecast. The record stays "running"
    /// so re-opening it reattaches via `resumePolling`/`hydrateFromBackend`.
    public func detach() {
        pollTask?.cancel()
        pollTask = nil
        persist(force: true)
    }

    public func cancel() {
        pollTask?.cancel()
        pollTask = nil
        let wasActive = phase.isActive
        if wasActive {
            phase = .cancelled
            record?.status = "cancelled"
            persist(force: true)
        }
        // Stopping the poll loop alone leaves the pipeline burning tokens
        // server-side — tell MiroFish to kill the DeerFlow/OASIS children too.
        if wasActive, let pid = pipelineID {
            let client = self.client
            Task.detached {
                do {
                    try await client.cancelPipeline(pid)
                    Log.engine.info("Forecast pipeline cancelled on backend: \(pid, privacy: .public)")
                } catch {
                    Log.engine.error("Backend cancel failed for \(pid, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Resume a failed/cancelled pipeline. MiroFish reuses completed stage
    /// artifacts (research dossier, graph, …), so this skips straight to the
    /// first incomplete stage instead of re-running everything.
    public func resume() {
        guard phase == .failed || phase == .cancelled, let pid = pipelineID else { return }
        guard pollTask == nil else { return }
        isRestored = false
        errorMessage = nil
        phase = .starting
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.client.resumePipeline(pid)
                guard !Task.isCancelled else { return }
                self.phase = .running
                self.record?.status = "running"
                self.persist(force: true)
                Log.engine.info("Forecast pipeline resumed: \(pid, privacy: .public)")
                await self.pollLoop(pipelineID: pid)
            } catch {
                self.failWith(error)
            }
        }
    }

    /// Called when the MiroFish backend couldn't be reached before the run could
    /// even start — fail cleanly with guidance instead of a doomed POST.
    public func reportBackendUnavailable(_ message: String) {
        guard phase == .idle || phase == .starting else { return }
        errorMessage = message
        phase = .failed
    }

    private func launch() async {
        do {
            let resp = try await client.runPipeline(prompt: prompt,
                                                    mode: mode.rawValue,
                                                    depth: depth,
                                                    projectName: nil,
                                                    maxRounds: maxRounds)
            guard !Task.isCancelled else { return }
            pipelineID = resp.pipeline_id
            record = try? store.createForecast(pipelineID: resp.pipeline_id,
                                               prompt: prompt,
                                               mode: mode.rawValue,
                                               depth: depth)
            phase = .running
            Log.engine.info("Forecast pipeline started: \(resp.pipeline_id, privacy: .public)")
            await pollLoop(pipelineID: resp.pipeline_id)
        } catch {
            failWith(error)
        }
    }

    private func pollLoop(pipelineID: String) async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            do {
                let state = try await client.pipelineStatus(pipelineID)
                consecutiveFailures = 0
                ingest(state)
                if state.status == "completed" {
                    await finalFetches(state)
                    phase = .completed
                    persist(force: true)
                    Log.engine.info("Forecast pipeline complete: \(pipelineID, privacy: .public)")
                    return
                }
                if state.status == "failed" {
                    errorMessage = state.error ?? "The MiroFish pipeline failed."
                    await finalFetches(state)   // still pull whatever was produced
                    phase = .failed
                    record?.status = "failed"
                    persist(force: true)
                    return
                }
                if state.status == "cancelled" {
                    // Cancelled out-of-band (another client, backend restart, …).
                    errorMessage = state.error
                    await finalFetches(state)
                    phase = .cancelled
                    record?.status = "cancelled"
                    persist(force: true)
                    return
                }
                await sideFetches(state)
                persist(force: false)
            } catch {
                // A single status hiccup shouldn't abort the run; only give up if
                // the backend stays unreachable for a long stretch.
                consecutiveFailures += 1
                if consecutiveFailures >= 30 {     // ~60s of failures
                    failWith(error)
                    return
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func failWith(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        phase = .failed
        record?.status = "failed"
        persist(force: true)
        Log.engine.error("Forecast pipeline error: \(self.errorMessage ?? "unknown", privacy: .public)")
    }

    // MARK: - Ingest pipeline status

    private func ingest(_ state: MFPipelineState) {
        globalProgress = state.global_progress
        currentStage = state.current_stage
        graphID = state.graph_id ?? graphID
        simulationID = state.simulation_id ?? simulationID
        reportID = state.report_id ?? reportID
        if let e = state.error, !e.isEmpty { errorMessage = e }

        for i in stages.indices {
            if let s = state.stages[stages[i].kind.rawValue] {
                stages[i].status = ForecastStageStatus(apiValue: s.status)
                stages[i].progress = s.progress
                stages[i].message = s.message ?? ""
            }
        }
    }

    /// Pull stage-specific resources based on what's currently available.
    private func sideFetches(_ state: MFPipelineState) async {
        // Research console (tail of DeerFlow's streamed log).
        if stageStatus(.research) == .running || (researchLines.isEmpty && stageStatus(.research) != .pending) {
            if let p = try? await client.researchProgress(state.pipeline_id, lines: 200) {
                researchLines = p.lines
            }
        }
        // Dossier once research is done.
        if dossier == nil, stageStatus(.research) == .completed {
            dossier = try? await client.dossier(state.pipeline_id)
        }
        // Ontology once a project exists.
        if ontology == nil, let pid = state.project_id, stageStatus(.ontology) != .pending {
            if let proj = try? await client.project(pid), let o = proj.ontology { ontology = o }
        }
        // Knowledge graph once a graph id exists. Keep refreshing while the graph
        // stage is still running (Zep extracts entities incrementally), then stop.
        if let gid = state.graph_id, graph == nil || stageStatus(.graph) == .running {
            if let data = try? await client.graphData(gid) {
                let next = ForecastGraph.from(data)
                if !next.isEmpty { graph = next }
            }
        }
        // Simulation telemetry while running / once present.
        if let sid = state.simulation_id,
           stageStatus(.run) == .running || stageStatus(.run) == .completed {
            if let detail = try? await client.runStatusDetail(sid) {
                runState = detail
                recentActions = detail.recent_actions ?? recentActions
            }
            if let t = try? await client.timeline(sid) { timeline = t.timeline }
        }
        // Report content + ReAct agent log.
        if let rid = state.report_id {
            await fetchReport(rid)
        }
    }

    /// Pull every artifact a finished (or terminal) pipeline produced, so a
    /// completed/imported forecast renders all stages — not just the ones that
    /// happened to stream in while we were polling. Each fetch is best-effort.
    private func finalFetches(_ state: MFPipelineState) async {
        if researchLines.isEmpty, stageStatus(.research) != .pending {
            if let p = try? await client.researchProgress(state.pipeline_id, lines: 200) {
                researchLines = p.lines
            }
        }
        if dossier == nil { dossier = try? await client.dossier(state.pipeline_id) }
        if ontology == nil, let pid = state.project_id {
            if let proj = try? await client.project(pid), let o = proj.ontology { ontology = o }
        }
        if let gid = state.graph_id, let data = try? await client.graphData(gid) {
            let next = ForecastGraph.from(data)
            if !next.isEmpty { graph = next }
        }
        if let sid = state.simulation_id {
            if let detail = try? await client.runStatusDetail(sid) {
                runState = detail
                recentActions = detail.recent_actions ?? recentActions
            }
            if timeline.isEmpty, let t = try? await client.timeline(sid) {
                timeline = t.timeline
            }
        }
        if let rid = state.report_id { await fetchReport(rid) }
    }

    private func fetchReport(_ reportID: String) async {
        if let r = try? await client.report(reportID) { report = r }
        if let p = try? await client.reportProgress(reportID) { reportProgress = p }
        if let log = try? await client.reportAgentLog(reportID, fromLine: agentLogCursor) {
            if !log.logs.isEmpty {
                agentLog.append(contentsOf: log.logs)
                if agentLog.count > 600 { agentLog.removeFirst(agentLog.count - 600) }
            }
            agentLogCursor = log.total_lines ?? agentLogCursor
        }
    }

    private func stageStatus(_ kind: ForecastStageKind) -> ForecastStageStatus {
        stages.first(where: { $0.kind == kind })?.status ?? .pending
    }

    // MARK: - Report agent chat

    /// True once the run can answer follow-up questions (the chat rides on the
    /// simulation's graph, so it needs a simulation id and a finished report).
    public var canChat: Bool {
        simulationID != nil && (report?.markdown_content?.isEmpty == false)
    }

    /// Ask the report agent a follow-up question. The agent re-queries the
    /// knowledge graph (and can interview live simulation agents), so a reply
    /// can take a minute or two — `chatBusy` drives the UI spinner.
    public func sendChat(_ message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chatBusy, let sid = simulationID else { return }
        chatError = nil
        chatBusy = true
        let history = chatMessages.map { MFChatTurn(role: $0.role.rawValue, content: $0.text) }
        chatMessages.append(ChatMessage(role: .user, text: text, toolNames: []))
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.chatBusy = false }
            do {
                let reply = try await self.client.reportChat(simulationID: sid,
                                                             message: text,
                                                             history: history)
                let body = reply.response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.chatMessages.append(ChatMessage(role: .assistant,
                                                     text: body.isEmpty ? "(no answer)" : body,
                                                     toolNames: reply.toolNames))
            } catch {
                self.chatError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: - Persistence

    private func persist(force: Bool) {
        guard let record else { return }
        let reportMarkdown = report?.markdown_content ?? ""
        // Avoid thrashing SwiftData: only write when something material changed.
        let reportChanged = reportMarkdown.count != lastPersistedReportLength
        guard force || reportChanged || record.globalProgress != globalProgress else { return }

        record.status = phase == .idle ? "running" : (phase.isTerminal ? phase.rawValue : "running")
        record.globalProgress = globalProgress
        record.graphID = graphID
        record.simulationID = simulationID
        record.reportID = reportID
        record.errorText = errorMessage
        if !reportMarkdown.isEmpty {
            record.reportMarkdown = reportMarkdown
            lastPersistedReportLength = reportMarkdown.count
        }
        if let graph, let data = try? JSONEncoder().encode(graph),
           let json = String(data: data, encoding: .utf8) {
            record.graphJSON = json
        }
        record.updatedAt = .now
        try? store.saveChanges()
    }

    // MARK: - Restore a stored forecast (read-only snapshot)

    public static func restored(from record: ForecastRecord,
                                client: MiroFishClient,
                                store: ResearchStore) -> ForecastRun {
        let mode = Mode(rawValue: record.mode) ?? .full
        let run = ForecastRun(prompt: record.prompt, mode: mode, depth: record.depth,
                              maxRounds: nil, client: client, store: store)
        run.isRestored = true
        run.record = record         // keep persisting resume/cancel/report updates
        run.pipelineID = record.pipelineID
        run.errorMessage = record.errorText
        run.globalProgress = record.globalProgress
        run.graphID = record.graphID
        run.simulationID = record.simulationID
        run.reportID = record.reportID
        run.graph = record.graphSnapshot
        run.phase = ForecastRun.Phase(rawValue: record.status) ?? .completed
        if !record.reportMarkdown.isEmpty {
            run.report = MFReport(report_id: record.reportID, simulation_id: record.simulationID,
                                  graph_id: record.graphID, simulation_requirement: record.prompt,
                                  status: "completed", outline: nil,
                                  markdown_content: record.reportMarkdown,
                                  created_at: nil, completed_at: nil, error: nil)
        }
        // Mark all stages completed for a finished restore so the stepper reads sensibly.
        if run.phase == .completed {
            for i in run.stages.indices { run.stages[i].status = .completed; run.stages[i].progress = 100 }
        }
        return run
    }

    /// Re-attach a restored run to its still-live pipeline and resume polling.
    public func resumePolling() {
        guard isRestored, let pid = pipelineID, !phase.isTerminal else { return }
        guard pollTask == nil else { return }
        isRestored = false
        phase = .running
        pollTask = Task { @MainActor [weak self] in await self?.pollLoop(pipelineID: pid) }
    }

    /// Best-effort re-fetch of a restored run's full artifacts (dossier, ontology,
    /// graph, report outline, …) from the backend. The stored snapshot only keeps
    /// the report markdown + graph; everything else comes back live when the
    /// backend is reachable. Never changes `phase` and fails silently offline.
    public func hydrateFromBackend() {
        guard isRestored, let pid = pipelineID else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let state = try? await self.client.pipelineStatus(pid) else { return }
            self.ingest(state)
            await self.finalFetches(state)
            // If the stored status drifted from the backend's truth (e.g. the app
            // quit mid-run and the pipeline finished on its own), adopt it.
            if self.phase.isTerminal || self.phase == .idle {
                switch state.status {
                case "completed": self.phase = .completed
                case "failed":
                    self.phase = .failed
                    self.errorMessage = self.errorMessage ?? state.error
                case "cancelled": self.phase = .cancelled
                case "running", "pending":
                    // Still live on the backend — reattach and follow it.
                    self.isRestored = false
                    self.phase = .running
                    if self.pollTask == nil {
                        self.pollTask = Task { @MainActor [weak self] in
                            await self?.pollLoop(pipelineID: pid)
                        }
                    }
                default: break
                }
                self.persist(force: true)
            }
        }
    }
}
