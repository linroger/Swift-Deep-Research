import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct SessionSidebar: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var modelContext
    let sessions: [StoredSession]
    @State private var search: String = ""
    /// Caches a precomputed lowercased searchable blob per session so the search
    /// filter doesn't re-lowercase every query/title/turn/source on each
    /// keystroke (each body re-eval). Invalidated per session by `updatedAt`.
    @State private var searchIndex = SessionSearchIndex()

    var body: some View {
        @Bindable var env = env
        List(selection: $env.selectedSessionID) {
            if let live = env.live, sessions.first(where: { $0.id == live.sessionID }) == nil {
                Section {
                    LiveSessionRow(live: live)
                        .tag(Optional(live.sessionID))
                } header: {
                    sectionLabel("Running", icon: "circle.fill", color: .accentColor)
                }
            }
            Section {
                if filtered.isEmpty && !search.isEmpty {
                    Text("No matches")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else if filtered.isEmpty {
                    Text("No sessions yet.\nAsk a question to begin.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(filtered) { session in
                        SessionRow(session: session, highlight: search)
                            .tag(Optional(session.id))
                            .contextMenu { contextMenu(for: session) }
                    }
                }
            } header: {
                sectionLabel(search.isEmpty ? "Recent" : "Matches",
                            icon: search.isEmpty ? "clock" : "magnifyingglass",
                            color: .secondary)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Deep Research")
        .searchable(text: $search,
                    placement: .sidebar,
                    prompt: "Search queries, sources, drafts")
    }

    private func sectionLabel(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
    }

    private var filtered: [StoredSession] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return sessions }
        let needle = search.lowercased()
        // Match against a per-session blob that's lowercased once and cached, so
        // a keystroke is O(sessions × one contains) rather than re-lowercasing
        // every turn's full markdown and every source on every body re-eval.
        return sessions.filter { searchIndex.blob(for: $0).contains(needle) }
    }

    @ViewBuilder
    private func contextMenu(for session: StoredSession) -> some View {
        Menu("Export…") {
            ForEach(SessionExporter.Format.allCases) { format in
                Button(format.displayName) {
                    exportSession(session, format: format)
                }
            }
        }
        Button(role: .destructive) {
            try? deleteSession(session)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func deleteSession(_ session: StoredSession) throws {
        modelContext.delete(session)
        try modelContext.save()
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
}

private struct SessionRow: View {
    let session: StoredSession
    var highlight: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                statusDot
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(highlighted(session.titleSummary.isEmpty ? session.query : session.titleSummary))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        Text(session.updatedAt, format: .relative(presentation: .named))
                        if session.totalTokens > 0 {
                            Text("·")
                            Text("\(session.totalTokens) tokens")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch StoredSession.Status(rawValue: session.status) ?? .running {
        case .running: .blue
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    private func highlighted(_ source: String) -> AttributedString {
        var attr = AttributedString(source)
        let needle = highlight.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty,
              let range = attr.range(of: needle, options: .caseInsensitive) else { return attr }
        attr[range].backgroundColor = .yellow.opacity(0.3)
        attr[range].font = .subheadline.weight(.bold)
        return attr
    }
}

private struct LiveSessionRow: View {
    let live: LiveSession
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(live.query)
                        .lineLimit(2)
                        .font(.subheadline.weight(.medium))
                    Text(live.status.rawValue.capitalized + "…")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tint)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Memoizes a lowercased searchable blob per session for the sidebar filter.
/// Building the blob walks every turn's markdown and every source once; the
/// result is cached by session id and rebuilt only when the session's
/// `updatedAt` changes, so per-keystroke filtering is a single `contains` over
/// the cached string instead of re-lowercasing the whole corpus each body pass.
/// MainActor-isolated because it is only ever read/mutated from the view body.
@MainActor
private final class SessionSearchIndex {
    private struct Entry { let stamp: Date; let blob: String }
    private var cache: [UUID: Entry] = [:]

    func blob(for session: StoredSession) -> String {
        if let entry = cache[session.id], entry.stamp == session.updatedAt {
            return entry.blob
        }
        var parts: [String] = [session.query, session.titleSummary]
        for turn in session.turns { parts.append(turn.markdown) }
        for src in session.sources { parts.append(src.title); parts.append(src.snippet) }
        let blob = parts.joined(separator: "\n").lowercased()
        cache[session.id] = Entry(stamp: session.updatedAt, blob: blob)
        return blob
    }
}
