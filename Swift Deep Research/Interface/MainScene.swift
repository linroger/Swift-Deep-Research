import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// Root window layout. Two columns by default (sidebar + canvas); the
/// inspector slides in only when there's something worth inspecting. The
/// canvas owns its own composer — no extra footer noise.
public struct MainScene: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredSession.updatedAt, order: .reverse) private var sessions: [StoredSession]
    @Query(sort: \ForecastRecord.updatedAt, order: .reverse) private var forecastRecords: [ForecastRecord]
    @State private var query: String = ""
    @State private var showSettings: Bool = false
    @State private var showDocuments: Bool = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State private var showInspector: Bool = false
    /// Identity of the session/run for which the inspector has already been
    /// auto-revealed, so the reveal fires at most once per context and a manual
    /// close isn't fought by the next status change. nil means "not yet
    /// revealed for the current context".
    @State private var autoRevealedContext: String?

    public init() {}

    public var body: some View {
        @Bindable var env = env
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                Picker("Workspace", selection: $env.workspace) {
                    ForEach(AppEnvironment.Workspace.allCases) { ws in
                        Label(ws.title, systemImage: ws.systemImage).tag(ws)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
                Divider()
                switch env.workspace {
                case .research:
                    SessionSidebar(sessions: sessions)
                case .forecast:
                    ForecastSidebar(records: forecastRecords)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            switch env.workspace {
            case .research:
                HStack(spacing: 0) {
                    ResearchCanvas(query: $query)

                    if showInspector && (env.live != nil || env.selectedSessionID != nil) {
                        Divider().opacity(0.4)
                        SourcePanel()
                            .frame(width: 340)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: showInspector)
            case .forecast:
                ForecastWorkspaceView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            if env.workspace == .research {
                ToolbarItem(placement: .navigation) {
                    Button {
                        // Cancel any in-flight run first (E3-ux-1) so it can't
                        // keep streaming/spending budget detached.
                        env.newResearchSession()
                        query = ""
                        // Clear inspector state so it doesn't leak into the next
                        // session (the auto-reveal will re-arm for fresh context).
                        showInspector = false
                        autoRevealedContext = nil
                    } label: {
                        Label("New Research", systemImage: "square.and.pencil")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New research (⌘N)")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if env.workspace == .research {
                    if env.live != nil || env.selectedSessionID != nil {
                        Toggle(isOn: $showInspector) {
                            Label("Inspector", systemImage: "sidebar.right")
                        }
                        .toggleStyle(.button)
                        .help("Toggle inspector (⌥⌘I)")
                        .keyboardShortcut("i", modifiers: [.option, .command])
                    }
                    exportMenu
                    Button { showDocuments = true } label: {
                        Label("Knowledge base", systemImage: "books.vertical.fill")
                    }
                    .help("Knowledge base (⌘⇧K)")
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                }
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings (⌘,)")
            }
        }
        .onChange(of: inspectorContextID) { _, newContext in
            // Context changed (New Research, picked another session, run ended):
            // re-arm the one-shot auto-reveal and don't let inspector state from
            // the previous session leak into the new one.
            autoRevealedContext = nil
            if newContext == nil { showInspector = false }
        }
        .onChange(of: env.live?.status) { _, newStatus in
            // Auto-reveal the inspector once per context the first time the
            // engine has something to show. Tracking the revealed context means
            // a later status change won't fight a manual close, and the reveal
            // doesn't re-fire for a session it already handled.
            guard let context = inspectorContextID, autoRevealedContext != context else { return }
            if let s = newStatus, s != LiveSession.Status.idle {
                autoRevealedContext = context
                showInspector = true
            }
        }
        .task {
            // First-run only: if the default config can't run keyless, adopt a
            // reachable local Ollama so the app works out of the box (E3-oobe-5).
            await env.autoConfigureLocalProviderIfNeeded()
            // Check whether the active providers have their API keys so first-run
            // guidance can appear before the user fires a doomed run.
            await env.refreshKeyStatus()
            // Boot the embedding sidecar in the background at app launch so
            // the Knowledge Base is instant when the user opens it. No-op if
            // it's already running.
            await SidecarSupervisor.shared.ensureRunning(
                host: env.configuration.seekdbHost
            )
        }
        .onChange(of: env.configuration.workerProvider) {
            Task { await env.refreshKeyStatus() }
        }
        .onChange(of: env.settingsOpen) { _, open in
            // Allow other views (e.g. the first-run banner) to request Settings.
            if open { showSettings = true; env.settingsOpen = false }
        }
        .onChange(of: showSettings) { _, open in
            // Re-check keys after the user closes Settings — they may have just
            // added one.
            if !open { Task { await env.refreshKeyStatus() } }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environment(env)
        }
        .sheet(isPresented: $showDocuments) {
            NavigationStack {
                DocumentUploadView(kb: KnowledgeBase(client: SeekDBClient(host: env.configuration.seekdbHost)))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showDocuments = false }
                        }
                    }
            }
            .frame(minWidth: 780, minHeight: 620)
        }
    }

    // MARK: - Toolbar bits

    @ViewBuilder
    private var exportMenu: some View {
        if let session = currentStoredSession {
            Menu {
                ForEach(SessionExporter.Format.allCases) { format in
                    Button("Export as \(format.displayName)") {
                        exportSession(session, format: format)
                    }
                }
                Divider()
                Button("Copy synthesis as Markdown") {
                    copySynthesis(session)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the current session")
        }
    }

    // MARK: - Session helpers

    /// Stable identity of the context the inspector is bound to: the live run's
    /// sessionID while a run is active, otherwise the selected stored session.
    /// nil when neither exists (e.g. after New Research) so the inspector can be
    /// dismissed and the auto-reveal re-armed. The "live:" / "stored:" prefixes
    /// keep the two namespaces distinct.
    private var inspectorContextID: String? {
        if let live = env.live { return "live:\(live.sessionID.uuidString)" }
        if let id = env.selectedSessionID { return "stored:\(id.uuidString)" }
        return nil
    }

    private var currentStoredSession: StoredSession? {
        guard let id = env.selectedSessionID else { return nil }
        let descriptor = FetchDescriptor<StoredSession>(
            predicate: #Predicate<StoredSession> { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func exportSession(_ session: StoredSession, format: SessionExporter.Format) {
        guard let payload = try? SessionExporter.export(session: session, format: format) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = payload.suggestedFilename
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? UTType.data]
        if panel.runModal() == .OK, let url = panel.url {
            try? payload.data.write(to: url)
        }
    }

    private func copySynthesis(_ session: StoredSession) {
        let md = SessionExporter.markdown(session: session)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }
}
