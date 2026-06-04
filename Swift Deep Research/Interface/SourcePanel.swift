import SwiftUI
import SwiftData
import AppKit

/// Right-pane inspector. Tabs the user can flip between:
///   - Sources: discovered + cited
///   - Activity: chronological event log
///   - Plan: the orchestrator's strategy + subtasks
struct SourcePanel: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab: InspectorTab = .sources
    /// KB chunk currently open in the reader sheet (kb:// URLs can't open in a
    /// browser, so tapping a knowledge-base source shows its text here).
    @State private var inspectedChunk: FetchedSource?

    enum InspectorTab: String, CaseIterable, Identifiable {
        case sources, activity, plan
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .sources: "link"
            case .activity: "waveform.path.ecg"
            case .plan: "list.bullet.rectangle"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            tabContent
        }
        .background(.regularMaterial.opacity(0.4))
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Inspector")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            ForEach(InspectorTab.allCases) { tab in
                Button { selectedTab = tab } label: {
                    Image(systemName: tab.icon)
                        .font(.caption.weight(.medium))
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selectedTab == tab ? Color.accentColor.opacity(0.22) : Color.clear)
                        )
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(tab.label)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .sources: sourcesTab
        case .activity:
            if let live = env.live {
                ActivityLog(entries: live.activityLog)
            } else {
                emptyState(label: "No live session", systemImage: "waveform.path.ecg")
            }
        case .plan:
            if let plan = env.live?.plan {
                planTab(plan: plan)
            } else {
                emptyState(label: "No plan yet", systemImage: "list.bullet.rectangle")
            }
        }
    }

    // MARK: - Sources tab

    @ViewBuilder
    private var sourcesTab: some View {
        List {
            if let live = env.live {
                liveSources(live: live)
            } else if let id = env.selectedSessionID,
                      let session = fetchSession(id) {
                storedSources(session: session)
            } else {
                Text("Run a query to see sources here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .sheet(item: $inspectedChunk) { chunk in
            KBChunkDetail(source: chunk)
        }
    }

    @ViewBuilder
    private func liveSources(live: LiveSession) -> some View {
        // Knowledge-base chunks the agent retrieved from the user's documents,
        // ranked by relevance. Tapping one opens its full text.
        let kbChunks = live.fetchedSources.values
            .filter(\.isKnowledgeBase)
            .sorted { ($0.relevanceScore ?? 0) > ($1.relevanceScore ?? 0) }
        let webFetched = live.fetchedSources.values.filter { !$0.isKnowledgeBase }

        if !kbChunks.isEmpty {
            Section("Knowledge base (\(kbChunks.count))") {
                ForEach(kbChunks, id: \.id) { chunk in
                    KBChunkRow(source: chunk) { inspectedChunk = chunk }
                }
            }
        }
        if !webFetched.isEmpty {
            Section("Fetched (\(webFetched.count))") {
                ForEach(webFetched, id: \.url) { f in
                    FetchedRow(source: f)
                }
            }
        }
        // Web discoveries only — KB hits already appear in their own section.
        let webDiscovered = live.discoveredSources.filter { $0.provider != "knowledge_base" }
        if !webDiscovered.isEmpty {
            Section("Discovered (\(webDiscovered.count))") {
                ForEach(webDiscovered) { s in
                    DiscoveredRow(source: s, fetched: live.fetchedSources[s.url] != nil)
                }
            }
        }
        if !live.citations.isEmpty {
            Section("Cited (\(live.citations.count))") {
                ForEach(live.citations) { c in
                    CitationRow(citation: c)
                }
            }
        }
    }

    @ViewBuilder
    private func storedSources(session: StoredSession) -> some View {
        Section("Fetched") {
            ForEach(session.sources.sorted(by: { $0.fetchedAt > $1.fetchedAt })) { src in
                StoredSourceRow(source: src)
            }
        }
    }

    @ViewBuilder
    private func planTab(plan: ResearchPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Strategy").font(.caption).foregroundStyle(.secondary)
                    Text(plan.strategy.rawValue.capitalized).font(.headline)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Restatement").font(.caption).foregroundStyle(.secondary)
                    Text(plan.restatement).font(.callout)
                }
                Divider()
                Text("Subtasks (\(plan.subtasks.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(plan.subtasks.enumerated()), id: \.offset) { idx, sub in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(idx + 1). \(sub.question)").font(.caption.weight(.medium))
                        Text(sub.rationale).font(.caption2).foregroundStyle(.secondary)
                        if !sub.suggestedQueries.isEmpty {
                            Text("Suggested: " + sub.suggestedQueries.joined(separator: " • "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                    .padding(8)
                    .background(.regularMaterial.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(12)
        }
    }

    private func emptyState(label: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 60)
    }

    private func fetchSession(_ id: UUID) -> StoredSession? {
        let descriptor = FetchDescriptor<StoredSession>(
            predicate: #Predicate<StoredSession> { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }
}

private struct FetchedRow: View {
    let source: FetchedSource
    @Environment(\.openURL) private var openURL
    @State private var hovered = false

    var body: some View {
        Button { openURL(source.url) } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title).font(.caption.weight(.medium)).lineLimit(2)
                    Text(source.url.host ?? "").font(.caption2).foregroundStyle(.secondary)
                    Text("\(source.extractedText.count.formatted()) chars • \(source.strategy.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(String(source.extractedText.prefix(600)) + (source.extractedText.count > 600 ? "…" : ""))
    }
}

private struct DiscoveredRow: View {
    let source: DiscoveredSource
    let fetched: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(source.url) } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: fetched ? "checkmark.seal.fill" : "circle.dotted")
                    .foregroundStyle(fetched ? .green : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title).font(.caption.weight(.medium)).lineLimit(2)
                    Text(source.url.host ?? "").font(.caption2).foregroundStyle(.secondary)
                    if let snippet = source.snippet, !snippet.isEmpty {
                        Text(snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(source.provider).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(source.snippet ?? source.title)
    }
}

/// A retrieved knowledge-base chunk. Tapping opens the full text — `kb://`
/// URLs have no browser handler, so we show the chunk inline instead.
private struct KBChunkRow: View {
    let source: FetchedSource
    let onOpen: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "text.book.closed.fill")
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(source.title).font(.caption.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        KBScoreBadge(score: source.relevanceScore)
                    }
                    Text(source.extractedText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc").font(.system(size: 8))
                        Text("\(source.extractedText.count.formatted()) chars • tap to read")
                            .font(.caption2)
                    }
                    .foregroundStyle(hovered ? Color.accentColor : Color.secondary.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Open knowledge-base chunk")
    }
}

private struct CitationRow: View {
    let citation: Citation
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button { openURL(citation.sourceURL) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(citation.claim).font(.caption.weight(.medium))
                Text("“\(citation.exactQuote)”")
                    .font(.caption2.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text(citation.sourceTitle).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct StoredSourceRow: View {
    let source: StoredSource
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button {
            if let url = source.url { openURL(url) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title).font(.caption.weight(.medium)).lineLimit(2)
                Text(source.urlString).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if !source.snippet.isEmpty {
                    Text(source.snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
