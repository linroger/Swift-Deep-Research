import Foundation
import Observation
import SwiftData

/// Single root @Observable that the UI watches. Owns the persistence store,
/// the active session view-model, and the in-memory event log for the
/// currently-running research run.
@MainActor
@Observable
public final class AppEnvironment {
    public var store: ResearchStore
    public var configuration: EngineConfiguration
    public var selectedSessionID: UUID?
    public var live: LiveSession?
    public var settingsOpen: Bool = false

    /// Non-nil when the active worker provider needs an API key that isn't in
    /// the Keychain yet — drives the first-run "add a key" guidance so a new
    /// user doesn't fire a doomed run and only learn the problem after it fails.
    /// Refreshed via `refreshKeyStatus()` on launch and whenever the provider or
    /// keys change.
    public var missingKeyHint: String?

    // MARK: Forecast workspace (DeerFlow × MiroFish prediction pipeline)

    /// Which workspace the main window is showing.
    public enum Workspace: String, Sendable, CaseIterable, Identifiable {
        case research, forecast
        public var id: String { rawValue }
        public var title: String { self == .research ? "Research" : "Forecast" }
        public var systemImage: String { self == .research ? "magnifyingglass" : "chart.line.uptrend.xyaxis" }
    }
    public var workspace: Workspace = .research
    /// The active (or restored) forecast pipeline, if any.
    public var forecast: ForecastRun?
    /// MiroFish backend location + launch preferences.
    public var forecastConfig: ForecastConfiguration = .suggestedDefault()
    /// Last-known MiroFish backend status, surfaced in the Forecast UI.
    public var forecastBackendStatus: MiroFishSupervisor.Status = .stopped

    /// UserDefaults key for the persisted engine configuration. Versioned so a
    /// schema change can invalidate stale blobs by bumping the suffix.
    private static let configKey = "engineConfiguration.v2"
    private static let forecastConfigKey = "forecastConfiguration.v1"

    public init(store: ResearchStore) {
        self.store = store
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let saved = try? JSONDecoder().decode(EngineConfiguration.self, from: data) {
            self.configuration = saved
        } else {
            self.configuration = EngineConfiguration.suggestedDefault()
        }
        if let data = UserDefaults.standard.data(forKey: Self.forecastConfigKey),
           let saved = try? JSONDecoder().decode(ForecastConfiguration.self, from: data) {
            self.forecastConfig = saved
        }
    }

    /// Persist the current configuration so provider/model/endpoint choices
    /// survive relaunch. Cheap; safe to call on every settings change.
    public func saveConfiguration() {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }

    public func saveForecastConfiguration() {
        if let data = try? JSONEncoder().encode(forecastConfig) {
            UserDefaults.standard.set(data, forKey: Self.forecastConfigKey)
        }
    }

    private func makeMiroFishClient() -> MiroFishClient {
        MiroFishClient(host: forecastConfig.host)
    }

    /// Begin a new forecast pipeline. Ensures the MiroFish backend is up first so
    /// the run doesn't fire a doomed `POST /api/research/run`.
    public func startForecast(prompt: String, mode: ForecastRun.Mode, depth: String, maxRounds: Int?) {
        forecast?.cancel()
        let run = ForecastRun(prompt: prompt, mode: mode, depth: depth, maxRounds: maxRounds,
                              client: makeMiroFishClient(), store: store)
        forecast = run
        Task { @MainActor in
            let status = await ensureForecastBackend()
            if case .running = status {
                run.start()
            } else {
                run.reportBackendUnavailable(Self.backendMessage(status))
            }
        }
    }

    /// Re-open a stored forecast as a read-only snapshot (resume if still live).
    public func openForecast(record: ForecastRecord) {
        forecast?.cancel()
        forecast = ForecastRun.restored(from: record, client: makeMiroFishClient(), store: store)
    }

    public func newForecast() {
        forecast?.cancel()
        forecast = nil
    }

    /// Make sure the MiroFish backend is reachable, launching it if auto-launch is
    /// on. Also syncs the user's Zep key into MiroFish's `.env` so the graph stage
    /// can authenticate (MiroFish reads `.env` with override, so env injection
    /// alone wouldn't stick).
    @discardableResult
    public func ensureForecastBackend() async -> MiroFishSupervisor.Status {
        await syncMiroFishEnv()
        let status: MiroFishSupervisor.Status
        if forecastConfig.autoLaunchBackend {
            status = await MiroFishSupervisor.shared.ensureRunning(host: forecastConfig.host,
                                                                   repoRoot: forecastConfig.repoRoot)
        } else {
            status = await MiroFishSupervisor.shared.checkHealth(host: forecastConfig.host)
        }
        forecastBackendStatus = status
        return status
    }

    /// Write the Zep key (entered under Settings → API keys) into MiroFish's `.env`.
    public func syncMiroFishEnv() async {
        let zep = await KeychainStore.shared.get(.zep) ?? ""
        guard !zep.isEmpty else { return }
        await MiroFishSupervisor.shared.syncEnv(["ZEP_API_KEY": zep], repoRoot: forecastConfig.repoRoot)
    }

    static func backendMessage(_ status: MiroFishSupervisor.Status) -> String {
        switch status {
        case .running: "MiroFish backend ready."
        case .launching: "The MiroFish backend is still starting — try again in a moment."
        case .stopped: "The MiroFish backend isn't running. Enable auto-launch in Settings → Forecast, or start it manually (`npm run dev`)."
        case .backendMissing(let m), .interpreterMissing(let m), .failed(let m): m
        }
    }

    /// Begin a new research run. Cancels any previous live run first.
    public func startResearch(query: String) {
        live?.cancel()
        let liveSession = LiveSession(query: query, configuration: configuration, store: store)
        self.live = liveSession
        self.selectedSessionID = liveSession.sessionID
        liveSession.start()
    }

    /// Ask a follow-up question on the active live session. Reuses sources
    /// already accumulated so the planner extends rather than restarts.
    public func askFollowUp(query: String) {
        guard let live, live.status == .complete || live.status == .failed else {
            startResearch(query: query)
            return
        }
        live.continueResearch(query: query)
    }

    public func cancelLive() {
        live?.cancel()
    }

    /// Refresh `missingKeyHint` by checking the Keychain for the active worker
    /// provider's key. Local providers (Ollama / LM Studio / MLX / Apple) need
    /// no key, so they always clear the hint.
    public func refreshKeyStatus() async {
        let provider = configuration.workerProvider
        guard let account = provider.requiresAPIKey else {
            missingKeyHint = nil
            return
        }
        let key = await KeychainStore.shared.get(account) ?? ""
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missingKeyHint = "\(provider.displayName) needs an API key. Open Settings → API keys to add one, or switch to a local model (Ollama, LM Studio, or Apple)."
        } else {
            missingKeyHint = nil
        }
    }
}

/// One in-flight research run. The orchestrator engine streams events into this
/// object; the UI observes its properties through `@Observable`.
@MainActor
@Observable
public final class LiveSession: Identifiable {
    public let sessionID: UUID
    public let query: String
    public let configuration: EngineConfiguration
    /// Wall-clock start of this run, for the live header timer.
    public let startedAt: Date = .now

    public var status: Status = .idle
    public var plan: ResearchPlan?
    public var workers: [WorkerID: WorkerSnapshot] = [:]
    public var discoveredSources: [DiscoveredSource] = []
    public var fetchedSources: [URL: FetchedSource] = [:]
    public var citations: [Citation] = []
    public var draftMarkdown: String = ""
    public var tokenStream: [TokenStreamEntry] = []
    public var activityLog: [ActivityEntry] = []
    public var failure: EngineFailure?
    public var totalTokens: Int = 0
    public var elapsed: Duration = .seconds(0)
    public var currentRound: Int = 0
    public var maxRounds: Int = 1
    public var lastCritique: Reflector.Critique?

    public enum Status: String, Sendable { case idle, planning, working, synthesizing, reflecting, complete, failed, cancelled }

    public struct ActivityEntry: Sendable, Identifiable {
        public let id = UUID()
        public let timestamp: Date
        public let kind: Kind
        public let title: String
        public let detail: String?

        public enum Kind: String, Sendable {
            case plan, worker, tool, source, draft, reflection, warning, error, iteration
        }
    }

    public struct WorkerSnapshot: Sendable, Identifiable {
        public var id: WorkerID { descriptor.id }
        public let descriptor: WorkerDescriptor
        public var lastMessage: String
        public var toolHistory: [ToolEvent]
        public var summary: String?

        public struct ToolEvent: Sendable, Identifiable {
            public let id = UUID()
            public let invocation: ToolInvocation
            public var outcome: ToolOutcome?
        }
    }

    public struct TokenStreamEntry: Sendable, Identifiable {
        public let id = UUID()
        public let stage: ResearchEvent.Stage
        public let text: String
    }

    /// Full transcript visible to the UI when the session has multiple turns.
    public var turnHistory: [TurnRecord] = []
    public struct TurnRecord: Sendable, Identifiable {
        public let id: UUID
        public let role: Role
        public let query: String
        public let markdown: String
        public let citations: [Citation]
        public let createdAt: Date
        public enum Role: String, Sendable { case user, assistant }
    }

    private let store: ResearchStore
    private var streamTask: Task<Void, Never>?
    private var storedSession: StoredSession?
    private var draftTurn: StoredTurn?
    private var eventSequence: Int = 0
    private var conversation: ConversationContext = ConversationContext()

    public init(query: String, configuration: EngineConfiguration, store: ResearchStore) {
        self.sessionID = UUID()
        self.query = query
        self.configuration = configuration
        self.store = store
    }

    public func start() {
        precondition(streamTask == nil, "LiveSession already started")
        status = .planning
        do {
            let providerName = configuration.workerProvider.displayName
            self.storedSession = try store.startSession(query: query, providerName: providerName)
            _ = try store.appendTurn(to: storedSession!, role: .user, markdown: query)
        } catch {
            self.failure = EngineFailure(kind: .unknown, message: "Failed to start session: \(error.localizedDescription)")
            self.status = .failed
            return
        }
        runEngine(query: query, contextOverride: conversation)
    }

    /// Follow-up turn. Resets per-turn state (workers, draft, citations) but
    /// preserves `conversation` and `turnHistory` so the planner has memory.
    public func continueResearch(query: String) {
        guard streamTask == nil || status == .complete || status == .failed || status == .cancelled else {
            return
        }
        // Archive the prior draft into the transcript before resetting.
        if !draftMarkdown.isEmpty {
            turnHistory.append(TurnRecord(
                id: UUID(),
                role: .user,
                query: self.query,
                markdown: "",
                citations: [],
                createdAt: .now
            ))
            turnHistory.append(TurnRecord(
                id: UUID(),
                role: .assistant,
                query: self.query,
                markdown: draftMarkdown,
                citations: citations,
                createdAt: .now
            ))
        }
        // Reset per-turn UI state; keep sources and conversation memory.
        plan = nil
        workers.removeAll()
        draftMarkdown = ""
        citations = []
        tokenStream.removeAll()
        lastCritique = nil
        failure = nil
        status = .planning
        draftTurn = nil
        currentRound = 0

        if let storedSession {
            _ = try? store.appendTurn(to: storedSession, role: .user, markdown: query)
        }
        runEngine(query: query, contextOverride: conversation)
    }

    private func runEngine(query: String, contextOverride: ConversationContext) {
        let engine = ResearchEngine(config: configuration)
        let id = sessionID
        let q = query
        streamTask = Task { @MainActor [weak self] in
            do {
                for try await event in engine.run(query: q, sessionID: id, context: contextOverride) {
                    guard let self else { return }
                    self.ingest(event)
                }
                guard let self else { return }
                self.streamTask = nil
                self.status = self.failure == nil ? .complete : .failed
                self.persistFinal()
                // Carry the just-completed draft into the conversation memory so
                // the next follow-up can build on it.
                self.conversation.appendUserTurn(q)
                if !self.draftMarkdown.isEmpty {
                    self.conversation.appendAssistantTurn(self.draftMarkdown)
                }
                self.conversation.accumulatedSources.append(contentsOf: self.fetchedSources.values)
                self.conversation.accumulatedCitations.append(contentsOf: self.citations)
            } catch {
                guard let self else { return }
                self.streamTask = nil
                self.failure = (error as? EngineFailure)
                    ?? EngineFailure(kind: .unknown, message: error.localizedDescription)
                self.status = .failed
                self.persistFinal()
            }
        }
    }

    public func cancel() {
        streamTask?.cancel()
        streamTask = nil
        if status != .complete { status = .cancelled }
    }

    private func ingest(_ event: ResearchEvent) {
        if let storedSession {
            let payload = (try? JSONEncoder().encode(EventEnvelope(event: event)))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            try? store.appendEvent(kind: eventKind(event),
                                   summary: eventSummary(event),
                                   payloadJSON: payload,
                                   sequence: eventSequence,
                                   session: storedSession)
            eventSequence += 1
        }
        switch event {
        case .sessionStarted: break
        case .iterationStarted(let round, let of):
            self.currentRound = round
            self.maxRounds = of
            self.status = .planning
            appendActivity(.iteration, "Iteration \(round) of \(of)", detail: nil)
        case .planEmitted(let p):
            self.plan = p
            self.status = .working
            appendActivity(.plan, "Plan: \(p.strategy.rawValue)",
                          detail: "\(p.subtasks.count) subtasks")
        case .workerStarted(let d):
            workers[d.id] = WorkerSnapshot(descriptor: d, lastMessage: "Started",
                                           toolHistory: [], summary: nil)
            appendActivity(.worker, "Worker \(d.id.raw) started", detail: d.task)
        case .workerProgress(let id, let msg):
            workers[id]?.lastMessage = msg
        case .toolInvoked(let id, let inv):
            workers[id]?.toolHistory.append(.init(invocation: inv, outcome: nil))
            appendActivity(.tool, "\(inv.name)", detail: "Worker \(id.raw)")
        case .toolResult(let id, let inv, let outcome):
            if var snap = workers[id],
               let idx = snap.toolHistory.lastIndex(where: { $0.invocation.id == inv.id }) {
                snap.toolHistory[idx].outcome = outcome
                workers[id] = snap
            }
        case .sourceDiscovered(_, let s):
            if !discoveredSources.contains(where: { $0.url == s.url }) {
                discoveredSources.append(s)
            }
        case .sourceFetched(_, let f):
            fetchedSources[f.url] = f
            appendActivity(.source, f.title, detail: f.url.host)
            if let storedSession {
                _ = try? store.upsertSource(f,
                                            snippet: discoveredSources.first(where: { $0.url == f.url })?.snippet,
                                            providerHint: discoveredSources.first(where: { $0.url == f.url })?.provider ?? "unknown",
                                            session: storedSession)
            }
        case .sourceCacheHit(let id, let url):
            appendActivity(.source, "Cache hit", detail: "Worker \(id.raw): \(url.host ?? url.absoluteString)")
        case .reasoningDelta(let id, let text):
            workers[id]?.lastMessage = String(text.prefix(220))
        case .tokenDelta(let stage, let text):
            if stage == .synthesis {
                draftMarkdown += text
                self.status = .synthesizing
            }
            tokenStream.append(TokenStreamEntry(stage: stage, text: text))
            if tokenStream.count > 4_000 { tokenStream.removeFirst(tokenStream.count - 4_000) }
        case .citationAdded(let c):
            if !citations.contains(where: { $0.id == c.id }) { citations.append(c) }
        case .workerCompleted(let id, let summary):
            workers[id]?.summary = summary
            appendActivity(.worker, "Worker \(id.raw) complete", detail: Clip.clip(summary, to: 120))
        case .draftReady(let descriptor):
            draftMarkdown = descriptor.markdown
            citations = descriptor.citations
            appendActivity(.draft, "Draft ready", detail: "\(descriptor.citations.count) citations")
            if let storedSession {
                if let draftTurn {
                    try? store.updateTurnMarkdown(draftTurn, markdown: descriptor.markdown)
                } else {
                    self.draftTurn = try? store.appendTurn(to: storedSession,
                                                           role: .assistant,
                                                           markdown: descriptor.markdown)
                }
                if let turn = self.draftTurn {
                    try? store.attachCitations(descriptor.citations, to: turn)
                }
            }
        case .reflectionStarted(let round):
            self.status = .reflecting
            appendActivity(.reflection, "Reflecting (round \(round))", detail: nil)
        case .reflectionEmitted(let critique):
            self.lastCritique = critique
            appendActivity(.reflection,
                          "Critique: \(critique.verdict.rawValue)",
                          detail: "\(critique.gaps.count) gaps, \(critique.unsupportedClaims.count) unsupported")
        case .reflectionConcluded(let continuing, let remaining):
            appendActivity(.reflection,
                          continuing ? "Continuing with \(remaining) more subtasks" : "Reflection complete",
                          detail: nil)
        case .sessionCompleted(let elapsed, let total):
            self.elapsed = elapsed
            self.totalTokens = total
            self.status = .complete
        case .warning(let s):
            appendActivity(.warning, s, detail: nil)
        case .error(let f):
            self.failure = f
            self.status = .failed
            appendActivity(.error, f.message, detail: f.kind.rawValue)
        }
    }

    private func appendActivity(_ kind: ActivityEntry.Kind, _ title: String, detail: String?) {
        activityLog.append(ActivityEntry(timestamp: .now, kind: kind, title: title, detail: detail))
        if activityLog.count > 500 { activityLog.removeFirst(activityLog.count - 500) }
    }

    private func persistFinal() {
        guard let storedSession else { return }
        let status: StoredSession.Status = switch self.status {
        case .complete: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        default: .running
        }
        try? store.markSession(storedSession, status: status, totalTokens: totalTokens)
    }

    private func eventKind(_ e: ResearchEvent) -> String {
        switch e {
        case .sessionStarted: "sessionStarted"
        case .iterationStarted: "iterationStarted"
        case .planEmitted: "planEmitted"
        case .workerStarted: "workerStarted"
        case .workerProgress: "workerProgress"
        case .toolInvoked: "toolInvoked"
        case .toolResult: "toolResult"
        case .sourceDiscovered: "sourceDiscovered"
        case .sourceFetched: "sourceFetched"
        case .sourceCacheHit: "sourceCacheHit"
        case .reasoningDelta: "reasoningDelta"
        case .tokenDelta: "tokenDelta"
        case .citationAdded: "citationAdded"
        case .workerCompleted: "workerCompleted"
        case .draftReady: "draftReady"
        case .reflectionStarted: "reflectionStarted"
        case .reflectionEmitted: "reflectionEmitted"
        case .reflectionConcluded: "reflectionConcluded"
        case .sessionCompleted: "sessionCompleted"
        case .warning: "warning"
        case .error: "error"
        }
    }

    private func eventSummary(_ e: ResearchEvent) -> String {
        switch e {
        case .sessionStarted(let d): "Session \(d.id) started"
        case .iterationStarted(let round, let of): "Iteration \(round)/\(of)"
        case .planEmitted(let p): "Plan: \(p.subtasks.count) subtasks (\(p.strategy.rawValue))"
        case .workerStarted(let d): "Worker \(d.id.raw) → \(d.task)"
        case .workerProgress(_, let m): m
        case .toolInvoked(_, let inv): "Tool \(inv.name)"
        case .toolResult(_, let inv, let outcome):
            switch outcome {
            case .ok(let s, _): "✓ \(inv.name): \(s)"
            case .failed(let m): "✗ \(inv.name): \(m)"
            }
        case .sourceDiscovered(_, let s): "Discovered: \(s.title)"
        case .sourceFetched(_, let f): "Fetched: \(f.title)"
        case .sourceCacheHit(let id, let url): "Cache hit \(id.raw): \(url.host ?? url.absoluteString)"
        case .reasoningDelta: "(reasoning)"
        case .tokenDelta: "(token)"
        case .citationAdded(let c): "Citation: \(c.claim)"
        case .workerCompleted(let id, _): "Worker \(id.raw) done"
        case .draftReady: "Draft ready"
        case .reflectionStarted(let r): "Reflection round \(r)"
        case .reflectionEmitted(let c): "Critique \(c.verdict.rawValue): \(c.gaps.count) gaps"
        case .reflectionConcluded(let cont, let n): cont ? "Continuing (\(n) follow-ups)" : "Reflection done"
        case .sessionCompleted(_, let t): "Complete (\(t) tokens)"
        case .warning(let s): "⚠ \(s)"
        case .error(let f): "✗ \(f.message)"
        }
    }
}

/// Codable wrapper so events can be persisted in `StoredEvent.payloadJSON`.
private struct EventEnvelope: Encodable {
    let kind: String
    let timestamp: Date
    let data: AnyJSON?

    init(event: ResearchEvent) {
        self.timestamp = .now
        switch event {
        case .planEmitted(let p):
            self.kind = "planEmitted"
            self.data = Self.encodeAny(p)
        case .draftReady(let d):
            self.kind = "draftReady"
            self.data = Self.encodeAny(d)
        case .citationAdded(let c):
            self.kind = "citationAdded"
            self.data = Self.encodeAny(c)
        default:
            self.kind = String(describing: event).prefix(while: { $0 != "(" }).description
            self.data = nil
        }
    }

    private static func encodeAny<T: Encodable>(_ value: T) -> AnyJSON? {
        guard let data = try? JSONEncoder().encode(value),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return try? AnyJSON.parse(str)
    }
}
