import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Document library UI. Lets the user:
///   - Drag-and-drop PDFs / markdown / text into pyseekdb
///   - Paste raw text snippets to embed
///   - See the current document list with chunk counts
///   - Test semantic queries to verify retrieval is working
///   - Delete documents or wipe the collection
///
/// All operations route through the local sidecar (`http://127.0.0.1:9100` by
/// default). When the sidecar is unreachable a tutorial card surfaces the
/// exact command to start it.
struct DocumentUploadView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var kb: KnowledgeBase
    @State private var pasteTitle: String = ""
    @State private var pasteBody: String = ""
    @State private var testQuery: String = ""
    @State private var testResults: [SeekDBClient.QueryHit] = []
    @State private var isDropping: Bool = false

    init(kb: KnowledgeBase? = nil) {
        // `_kb` initializer requires a State wrapper.
        _kb = State(initialValue: kb ?? KnowledgeBase())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                healthBanner
                dropZone
                pasteCard
                testCard
                documentList
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 600)
        .task { await kb.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Knowledge base")
                .font(.title.weight(.bold))
            Text("Embed your own PDFs, notes, and references with pyseekdb. Toggle the knowledge base on a research run to have workers search these alongside the open web.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var healthBanner: some View {
        switch kb.health {
        case .ok(let docs, let mode):
            Label("Sidecar online\(mode.map { " (\($0))" } ?? "") — \(docs) document\(docs == 1 ? "" : "s") indexed",
                  systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .padding(10)
                .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        case .unreachable(let host):
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't start the embedding sidecar", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Tried to auto-launch at \(host). If Python or the required packages are missing, install them once:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("python3 -m pip install pyseekdb fastapi uvicorn pydantic")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                if let detail = kb.lastError {
                    Text(detail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
                Button("Retry") { Task { await kb.refresh() } }
                    .buttonStyle(.bordered)
            }
            .padding(12)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        case .launching:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Starting the embedding sidecar…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        case .unknown:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking sidecar at \(env.configuration.seekdbHost.absoluteString)…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.title)
                .foregroundStyle(.tint)
            Text("Drop PDFs, markdown, or text files here")
                .font(.subheadline.weight(.medium))
            Button("Choose files…") { pickFiles() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDropping ? Color.accentColor : Color.secondary.opacity(0.3),
                              style: StrokeStyle(lineWidth: 1.5, dash: [4]))
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropping) { providers in
            handleDrop(providers: providers)
        }
    }

    @ViewBuilder
    private var pasteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Paste a snippet", systemImage: "text.cursor")
                    .font(.headline)
                Spacer()
                Button("Embed") {
                    Task {
                        await kb.ingest(title: pasteTitle.isEmpty ? "Snippet" : pasteTitle,
                                        text: pasteBody,
                                        source: "manual-paste")
                        pasteTitle = ""; pasteBody = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pasteBody.trimmingCharacters(in: .whitespaces).isEmpty || kb.isBusy)
            }
            TextField("Title (optional)", text: $pasteTitle)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $pasteBody)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
        .glassCard()
    }

    @ViewBuilder
    private var testCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Test a query", systemImage: "magnifyingglass")
                    .font(.headline)
                Spacer()
                Button("Search") {
                    Task { testResults = await kb.search(testQuery, k: 6) }
                }
                .buttonStyle(.bordered)
                .disabled(testQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            TextField("Ask something the workers might ask…", text: $testQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    Task { testResults = await kb.search(testQuery, k: 6) }
                }
            if !testResults.isEmpty {
                ForEach(Array(testResults.enumerated()), id: \.offset) { idx, hit in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(idx + 1). \(hit.title)").font(.subheadline.weight(.semibold))
                            Spacer()
                            if let score = hit.score {
                                Text(String(format: "%.2f", score))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tint)
                            }
                        }
                        Text(hit.text).font(.caption).lineLimit(4)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(.regularMaterial.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(14)
        .glassCard()
    }

    @ViewBuilder
    private var documentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Documents (\(kb.documents.count))", systemImage: "books.vertical.fill")
                    .font(.headline)
                Spacer()
                Button("Refresh") { Task { await kb.refresh() } }
                    .buttonStyle(.borderless)
                if !kb.documents.isEmpty {
                    Button(role: .destructive) {
                        Task { await kb.reset() }
                    } label: {
                        Label("Reset all", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }
            if kb.documents.isEmpty {
                ContentUnavailableView("No documents yet",
                                       systemImage: "tray",
                                       description: Text("Drop a file above or paste text to start building your private knowledge base."))
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(kb.documents) { doc in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title).font(.body.weight(.medium))
                            HStack(spacing: 6) {
                                Text("\(doc.chunks) chunks").font(.caption2)
                                if let source = doc.source {
                                    Text("•").font(.caption2)
                                    Text(source).font(.caption2).truncationMode(.middle).lineLimit(1)
                                }
                                if let added = doc.added_at {
                                    Text("•").font(.caption2)
                                    Text(added.prefix(10)).font(.caption2)
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await kb.delete(id: doc.id) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(.regularMaterial.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if let error = kb.lastError {
                Label(error, systemImage: "exclamationmark.bubble.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .glassCard()
    }

    // MARK: - File handling

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.supportedContentTypes
        if panel.runModal() == .OK {
            Task {
                for url in panel.urls {
                    await kb.ingestFile(at: url)
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var consumedAny = false
        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            consumedAny = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    await kb.ingestFile(at: url)
                }
            }
        }
        return consumedAny
    }

    private static var supportedContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .text, .json, .html, .commaSeparatedText]
        for ext in ["md", "markdown", "yaml", "yml"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }
}
