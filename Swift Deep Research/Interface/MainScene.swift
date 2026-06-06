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
    @State private var query: String = ""
    @State private var showSettings: Bool = false
    @State private var showDocuments: Bool = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State private var showInspector: Bool = false

    public init() {}

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebar(sessions: sessions)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
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
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    env.live = nil
                    env.selectedSessionID = nil
                    query = ""
                } label: {
                    Label("New Research", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New research (⌘N)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
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
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings (⌘,)")
            }
        }
        .onChange(of: env.live?.status) { _, newStatus in
            // Auto-reveal inspector once the engine has something to show.
            if let s = newStatus, s != LiveSession.Status.idle, !showInspector {
                showInspector = true
            }
        }
        .task {
            // Check whether the active provider has its API key so first-run
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
