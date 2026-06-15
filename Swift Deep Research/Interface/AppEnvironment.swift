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
    /// Unified model-provider manager: one vocabulary (`ModelRole`) for every
    /// LLM consumer in the app. Research roles persist in `configuration`;
    /// the forecast role lives here and is bridged to the MiroFish backend.
    public let modelProviders = ModelProviderManager()
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
    /// Presents the Forecast setup assistant (first run, or via banner/Settings).
    public var forecastOnboardingOpen: Bool = false
    /// Auto-present the assistant at most once per app session.
    private var forecastOnboardingAutoShown = false

    /// Pop the setup assistant when the Forecast workspace first opens on a
    /// machine where the backend isn't ready and onboarding never completed.
    public func maybeAutoPresentForecastOnboarding() {
        guard !forecastOnboardingAutoShown, !ForecastOnboarding.hasCompletedOnce else { return }
        switch forecastBackendStatus {
        case .running, .launching: return
        case .stopped, .backendMissing, .interpreterMissing, .failed:
            forecastOnboardingAutoShown = true
            forecastOnboardingOpen = true
        }
    }

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
        detachForecast()   // don't kill a still-running pipeline; just stop following it
        let client = makeMiroFishClient()
        let run = ForecastRun(prompt: prompt, mode: mode, depth: depth, maxRounds: maxRounds,
                              client: client, store: store)
        forecast = run
        Task { @MainActor in
            let status = await ensureForecastBackend()
            guard case .running = status else {
                run.reportBackendUnavailable(Self.backendMessage(status))
                return
            }
            // Preflight before spending: catch a misconfigured provider / invalid
            // GRAPH_BACKEND / placeholder credential up front, instead of learning
            // it only after the (expensive) research stage has begun (E3-forecast-1).
            // Offline checks only, so this adds negligible latency. If the endpoint
            // is unavailable (older backend), `try?` yields nil and we proceed.
            if let pf = try? await client.preflight(mode: mode.rawValue), !pf.ready {
                let detail = pf.errors.isEmpty
                    ? "The forecast backend isn't ready to run — check Settings → Forecast and your provider key."
                    : "The forecast backend isn't ready:\n• " + pf.errors.joined(separator: "\n• ")
                run.reportBackendUnavailable(detail)
                return
            }
            run.start()
        }
    }

    /// Re-open a stored forecast. Runs that were live when the app last quit
    /// reattach to their pipeline automatically; finished runs re-hydrate their
    /// full artifacts (dossier, ontology, outline, …) from the backend when it's
    /// reachable, falling back to the stored snapshot offline.
    public func openForecast(record: ForecastRecord) {
        detachForecast()
        let run = ForecastRun.restored(from: record, client: makeMiroFishClient(), store: store)
        forecast = run
        if record.status == "running" {
            // The pipeline may still be live server-side — reconnect and follow.
            Task { @MainActor in
                let status = await ensureForecastBackend()
                if case .running = status {
                    run.resumePolling()
                } else {
                    run.hydrateFromBackend()   // no-op offline; keeps snapshot
                }
            }
        } else {
            run.hydrateFromBackend()
        }
    }

    public func newForecast() {
        detachForecast()
        forecast = nil
    }

    /// Delete a stored forecast, and best-effort remove the matching pipeline
    /// (with its handoff artifacts) on the MiroFish backend so the two sides
    /// don't drift apart.
    public func deleteForecast(record: ForecastRecord) {
        if forecast?.pipelineID == record.pipelineID {
            forecast?.cancel()
            forecast = nil
        }
        let pipelineID = record.pipelineID
        do {
            try store.deleteForecast(record)
        } catch {
            // Don't swallow silently — a failed local delete leaves a phantom row
            // in the sidebar with no signal to the user or logs.
            Log.engine.error("Failed to delete forecast \(pipelineID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        let client = makeMiroFishClient()
        Task.detached {
            try? await client.deletePipeline(pipelineID)
        }
    }

    // MARK: Backend pipeline browser

    /// Every pipeline MiroFish knows about (started from this app, the web UI,
    /// or run_simulation.py). Drives the sidebar's "On backend" section.
    public var backendPipelines: [MFPipelineSummary] = []
    public var backendPipelinesRefreshing = false

    /// Refresh the backend pipeline list. Keeps the previous list on transport
    /// errors so a momentary hiccup doesn't blank the sidebar.
    public func refreshBackendPipelines() async {
        guard !backendPipelinesRefreshing else { return }
        backendPipelinesRefreshing = true
        defer { backendPipelinesRefreshing = false }
        if let pipelines = try? await makeMiroFishClient().listPipelines() {
            backendPipelines = pipelines
        }
    }

    /// Open a pipeline that lives only on the backend: import it as a local
    /// `ForecastRecord` (so it joins the regular sidebar and survives offline),
    /// then open it through the normal restore + hydrate path, which pulls the
    /// research dossier, ontology, knowledge graph, simulation telemetry, and
    /// the prediction report.
    public func openBackendPipeline(_ summary: MFPipelineSummary) {
        if let existing = try? store.findForecast(pipelineID: summary.pipeline_id) {
            openForecast(record: existing)
            return
        }
        Task { @MainActor in
            let client = makeMiroFishClient()
            do {
                let state = try await client.pipelineStatus(summary.pipeline_id)
                let record = try store.createForecast(pipelineID: state.pipeline_id,
                                                      prompt: state.prompt,
                                                      mode: state.mode,
                                                      depth: state.options?.depth ?? "standard")
                // "pending" isn't a ForecastRun.Phase; treat it as running so a
                // queued pipeline reattaches and follows along.
                record.status = state.status == "pending" ? "running" : state.status
                record.globalProgress = state.global_progress
                record.graphID = state.graph_id
                record.simulationID = state.simulation_id
                record.reportID = state.report_id
                record.errorText = state.error
                try? store.saveChanges()
                openForecast(record: record)
            } catch {
                Log.engine.error("Backend pipeline import failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Delete a backend-only pipeline (its record + handoff artifacts on the
    /// server). Running pipelines are refused by the backend with a 409.
    public func deleteBackendPipeline(_ summary: MFPipelineSummary) {
        let client = makeMiroFishClient()
        Task { @MainActor in
            try? await client.deletePipeline(summary.pipeline_id)
            await refreshBackendPipelines()
        }
    }

    /// Stop following the current run in the UI *without* cancelling it on the
    /// backend — switching to another forecast shouldn't kill a live pipeline.
    private func detachForecast() {
        guard let forecast else { return }
        if forecast.phase.isActive {
            forecast.detach()
        } else {
            forecast.cancel()
        }
    }

    /// Make sure the forecast backend is reachable, launching it if auto-launch is
    /// on. Also syncs the unified LLM provider into the backend's `.env` so a
    /// cold-started backend boots onto the user's provider (the backend reads
    /// `.env` with override, so env injection alone wouldn't stick). The knowledge
    /// graph runs locally (Graphiti), so no graph credential is synced.
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
        if case .running = status {
            // Keep the backend on the unified forecast provider. Idempotent;
            // applies to newly started pipelines only.
            await modelProviders.pushForecastProvider(client: makeMiroFishClient(),
                                                      config: configuration)
        }
        return status
    }

    /// Write the unified forecast LLM provider into the backend's `.env`, so a
    /// cold-started backend boots straight onto the user's configuration. The
    /// knowledge graph runs locally (Graphiti + embedded FalkorDB), so there is no
    /// graph credential to sync.
    public func syncMiroFishEnv() async {
        let updates = await modelProviders.envSeed(config: configuration)
        guard !updates.isEmpty else { return }
        await MiroFishSupervisor.shared.syncEnv(updates, repoRoot: forecastConfig.repoRoot)
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

    /// Refresh `missingKeyHint` — the first-run guidance banner — by checking
    /// EVERY role the run will exercise (orchestrator, worker, synthesis), not
    /// just the worker, so a keyed orchestrator/synthesis with no key surfaces
    /// the friendly banner instead of an opaque mid-run 401 (E3-engine-3 / E3-oobe-5).
    /// When all keyed roles have keys, fall back to a tool-calling caveat if the
    /// worker can't use tools (web-less research) so the user knows why a local
    /// default returns un-grounded answers (E3-llm-3). Local providers need no key.
    public func refreshKeyStatus() async {
        let roles: [(String, ProviderRegistry.ProviderID)] = [
            ("Orchestrator", configuration.orchestratorProvider),
            ("Worker", configuration.workerProvider),
            ("Synthesis", configuration.synthesisProvider),
        ]
        for (label, provider) in roles {
            guard let account = provider.requiresAPIKey else { continue }
            let key = await KeychainStore.shared.get(account) ?? ""
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                missingKeyHint = "\(label) model (\(provider.displayName)) needs an API key. Open Settings → API keys to add one, or switch to a local model (Ollama, LM Studio, or Apple)."
                return
            }
        }
        // Every keyed role has a key. Surface a tool-calling caveat when the
        // worker can't fetch the web / knowledge base, so research-without-web
        // isn't silently mistaken for grounded research.
        if !configuration.workerProvider.supportsToolCalling {
            missingKeyHint = "The worker model (\(configuration.workerProvider.displayName)) can't use web search or the knowledge base, so research relies on the model's built-in knowledge. Switch the Worker role to Ollama or a hosted provider in Settings for web-grounded research."
        } else {
            missingKeyHint = nil
        }
    }

    /// First-run only: when the default config isn't cleanly runnable (a keyed
    /// role is missing its key, or the worker can't tool-call), probe a local
    /// Ollama server and, if it's reachable with at least one installed model,
    /// route all three roles to it — giving a zero-key, web-capable default with
    /// no configuration (E3-oobe-5). Runs at most once per install; never clobbers
    /// a config the user has already customized away from the suggested default.
    public func autoConfigureLocalProviderIfNeeded() async {
        let flag = "didAutoConfigureLocalProvider.v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }

        // Is the current config already cleanly runnable? (every keyed role has a
        // key AND the worker can tool-call) — if so, leave it alone.
        var needsHelp = !configuration.workerProvider.supportsToolCalling
        for provider in [configuration.orchestratorProvider, configuration.workerProvider, configuration.synthesisProvider] {
            if let account = provider.requiresAPIKey {
                let key = (await KeychainStore.shared.get(account) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty { needsHelp = true }
            }
        }
        guard needsHelp else {
            UserDefaults.standard.set(true, forKey: flag)
            return
        }

        // Probe Ollama (the most common local setup). If reachable with models,
        // adopt it for all three roles so research is keyless AND tool-capable.
        guard let models = try? await OllamaClient.listModels(host: configuration.ollamaHost),
              let first = models.first else {
            // No local provider found; leave the keyed default + banner in place.
            // Don't set the flag — retry the probe on a later launch (Ollama may
            // be installed after first run).
            return
        }
        configuration.orchestratorProvider = .ollama
        configuration.orchestratorModel = first
        configuration.workerProvider = .ollama
        configuration.workerModel = first
        configuration.synthesisProvider = .ollama
        configuration.synthesisModel = first
        saveConfiguration()
        UserDefaults.standard.set(true, forKey: flag)
        await refreshKeyStatus()
    }

    /// Single entry point for "start a fresh research session". Cancels any
    /// in-flight run FIRST so an orphaned engine can't keep streaming, persisting,
    /// and spending the user's API budget after the UI moved on (E3-ux-1). All
    /// New Research affordances (toolbar, ⌘N, canvas) route through here.
    public func newResearchSession() {
        cancelLive()
        live = nil
        selectedSessionID = nil
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
    public var activityLog: [ActivityEntry] = []
    public var failure: EngineFailure?
    public var totalTokens: Int = 0
    public var elapsed: Duration = .seconds(0)
    public var currentRound: Int = 0
    public var maxRounds: Int = 1
    public var lastCritique: Reflector.Critique?

    public enum Status: String, Sendable {
        case idle, planning, working, synthesizing, reflecting, complete, failed, cancelled
        /// Active phases where a stream task is expected to be running.
        var isInflight: Bool {
            switch self {
            case .planning, .working, .synthesizing, .reflecting: true
            case .idle, .complete, .failed, .cancelled: false
            }
        }
    }

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
    // `@ObservationIgnored` (no view observes a Task handle) + `nonisolated(unsafe)`
    // so the nonisolated `deinit` can cancel it. Assigned only on the MainActor and
    // read from deinit at end-of-life when no other reference exists (no real race);
    // a `Task` handle is Sendable.
    @ObservationIgnored private nonisolated(unsafe) var streamTask: Task<Void, Never>?
    private var storedSession: StoredSession?
    private var draftTurn: StoredTurn?
    private var eventSequence: Int = 0
    private var conversation: ConversationContext = ConversationContext()
    /// The question driving the *current* turn. Unlike the immutable `query`
    /// (the original session prompt), this advances with each follow-up, so the
    /// archived transcript labels every turn with the actual question asked.
    private var activeQuery: String

    public init(query: String, configuration: EngineConfiguration, store: ResearchStore) {
        self.sessionID = UUID()
        self.query = query
        self.activeQuery = query
        self.configuration = configuration
        self.store = store
    }

    /// A run is in flight when its stream task exists and the status hasn't yet
    /// reached a terminal state. Single source of truth for both `start()` and
    /// `continueResearch()` so the re-entrancy rule lives in one place.
    private var isRunning: Bool {
        streamTask != nil && status.isInflight
    }

    public func start() {
        // A graceful early-return, not a `precondition` — a double-start must not
        // crash the app on a user-facing action; just ignore the redundant call.
        guard !isRunning else {
            Log.engine.warning("LiveSession.start() ignored: a run is already in flight")
            return
        }
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
        // Refuse a follow-up while a turn is still streaming; uses the same
        // `isRunning` rule as `start()` rather than re-deriving the condition.
        guard !isRunning else { return }
        // Archive the prior draft into the transcript before resetting. Use
        // `activeQuery` — the question that actually produced this draft — not
        // `self.query` (the immutable original prompt), so 2nd+ follow-ups don't
        // mislabel every archived turn with the first question's text.
        if !draftMarkdown.isEmpty {
            let priorQuery = activeQuery
            turnHistory.append(TurnRecord(
                id: UUID(),
                role: .user,
                query: priorQuery,
                markdown: "",
                citations: [],
                createdAt: .now
            ))
            turnHistory.append(TurnRecord(
                id: UUID(),
                role: .assistant,
                query: priorQuery,
                markdown: draftMarkdown,
                citations: citations,
                createdAt: .now
            ))
        }
        // This follow-up's question becomes the active one for the next archive.
        activeQuery = query
        // Reset per-turn UI state; keep sources and conversation memory.
        plan = nil
        workers.removeAll()
        draftMarkdown = ""
        citations = []
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

    /// Defense-in-depth: if the last reference is dropped without an explicit
    /// `cancel()`, stop the in-flight engine run so a leaked stream doesn't keep
    /// burning tokens. `deinit` is nonisolated, but a `Task` handle is `Sendable`
    /// and safe to cancel from any isolation, so we cancel it directly.
    deinit {
        streamTask?.cancel()
    }

    /// Whether an event warrants a durable `StoredEvent` row. Transient,
    /// high-frequency streaming deltas are excluded so the persistence layer
    /// isn't hit thousands of times per run on the MainActor (see `ingest`).
    private static func shouldPersist(_ event: ResearchEvent) -> Bool {
        switch event {
        case .tokenDelta, .reasoningDelta, .workerProgress, .sourceCacheHit:
            return false
        default:
            return true
        }
    }

    private func ingest(_ event: ResearchEvent) {
        // High-frequency streaming deltas (one `.tokenDelta`/`.reasoningDelta`
        // per token, plus chatty worker progress / cache hits) are live-UI only.
        // Persisting each one ran `EventEnvelope` JSON-encode + a synchronous
        // SwiftData `context.save()` on the MainActor — thousands of blocking
        // SQLite transactions during synthesis, the dominant cause of beachballing
        // on long "thorough" runs. The durable record is the final draft (persisted
        // on `.draftReady`) and the meaningful timeline events below; the token
        // stream is reconstructable from the draft and is never replayed verbatim.
        if let storedSession, Self.shouldPersist(event) {
            // Persist the FULL event via the loss-less overload: the store builds a
            // Codable `ResearchEventSnapshot` covering every event kind (not just the
            // three the old string envelope captured) and derives `kind`/payload from
            // it, so the persisted timeline is reconstructable for any kind
            // (event-envelope-lossy-payload-12).
            try? store.appendEvent(event: event,
                                   summary: eventSummary(event),
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
                    // Replace, don't append: reflection re-emits `.draftReady` for
                    // the SAME turn, and each run mints fresh citation ids, so a
                    // plain attach would duplicate the set once per round.
                    try? store.replaceCitations(descriptor.citations, on: turn)
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
