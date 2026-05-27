import SwiftUI

/// Right-pane activity feed showing every event the engine emits in
/// chronological order. This is what the user watches when they want to
/// understand "what is the agent actually doing right now".
struct ActivityLog: View {
    let entries: [LiveSession.ActivityEntry]
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all, tool, source, reflection, errors
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if filtered.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "waveform.path.ecg",
                    description: Text("Start a research run to see the engine's plan, tool calls, and reflections.")
                )
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filtered) { entry in
                            ActivityRow(entry: entry)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .padding(8)
    }

    private var header: some View {
        HStack {
            Label("Activity", systemImage: "waveform.path.ecg")
                .font(.headline)
            Spacer()
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 130)
        }
        .padding(.horizontal, 8)
    }

    private var filtered: [LiveSession.ActivityEntry] {
        switch filter {
        case .all: return entries
        case .tool: return entries.filter { $0.kind == .tool }
        case .source: return entries.filter { $0.kind == .source }
        case .reflection: return entries.filter { $0.kind == .reflection || $0.kind == .iteration }
        case .errors: return entries.filter { $0.kind == .error || $0.kind == .warning }
        }
    }
}

private struct ActivityRow: View {
    let entry: LiveSession.ActivityEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 16, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(.regularMaterial.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private var icon: String {
        switch entry.kind {
        case .plan: "list.bullet.rectangle"
        case .iteration: "arrow.triangle.2.circlepath"
        case .worker: "person.fill"
        case .tool: "wrench.and.screwdriver.fill"
        case .source: "link"
        case .draft: "doc.text.fill"
        case .reflection: "brain.head.profile"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .plan, .iteration: .accentColor
        case .worker: .blue
        case .tool: .indigo
        case .source: .teal
        case .draft: .green
        case .reflection: .purple
        case .warning: .yellow
        case .error: .red
        }
    }
}
