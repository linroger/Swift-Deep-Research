import SwiftUI
import MarkdownUI

/// Stage 1 panel: the DeerFlow deep-research console (a live tail of the agent's
/// streamed tool calls) plus the resulting dossier — researched actors, hot
/// topics, cited sources, and the full research report.
struct ResearchConsoleView: View {
    let run: ForecastRun

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                console
                if let dossier = run.dossier {
                    dossierView(dossier)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Live console

    private var console: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Research console", systemImage: "terminal", accent: .green)
            if run.researchLines.isEmpty {
                Text(run.stages.first?.status == .pending
                     ? "Waiting for the deep-research agent to start…"
                     : "Streaming DeerFlow research…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(run.researchLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(colorFor(line))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                            Color.clear.frame(height: 1).id(-1)
                        }
                        .padding(10)
                    }
                    .frame(height: 240)
                    .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 10))
                    .onChange(of: run.researchLines.count) {
                        withAnimation { proxy.scrollTo(-1, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func colorFor(_ line: String) -> Color {
        let l = line.lowercased()
        if l.contains("[error]") { return .red }
        if l.contains("[ok]") || l.contains("[done]") { return .green }
        if l.contains("[tool]") { return .cyan }
        if l.contains("[stage]") || l.contains("[init]") { return .orange }
        return .secondary
    }

    // MARK: - Dossier

    @ViewBuilder
    private func dossierView(_ dossier: MFDossier) -> some View {
        let actors = dossier.actorList
        let topics = dossier.hotTopics
        let sources = dossier.sourceList

        if !actors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Actors (\(actors.count))", systemImage: "person.2.fill", accent: .indigo)
                ForEach(actors) { actor in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.indigo)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(actor.displayName).font(.callout.weight(.semibold))
                                if let type = actor.type {
                                    Text(type).font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.indigo.opacity(0.15), in: Capsule())
                                }
                            }
                            if let role = actor.role { Text(role).font(.caption).foregroundStyle(.secondary) }
                            if let stance = actor.stance, !stance.isEmpty {
                                Text("Stance: \(stance)").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }

        if !topics.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Hot topics", systemImage: "flame.fill", accent: .orange)
                FlowLayout(spacing: 6) {
                    ForEach(topics, id: \.self) { topic in
                        Text(topic)
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .lineLimit(1)
                    }
                }
            }
        }

        if let report = dossier.report, !report.isEmpty {
            DisclosureGroup {
                Markdown(report)
                    .textSelection(.enabled)
                    .padding(.top, 6)
            } label: {
                sectionHeader("Research report", systemImage: "doc.text", accent: .teal)
            }
        }

        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Sources (\(sources.count))", systemImage: "link", accent: .blue)
                ForEach(sources) { src in
                    if let url = URL(string: src.url), url.scheme != nil {
                        Link(destination: url) {
                            Text(src.title.isEmpty ? src.url : src.title)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    } else {
                        Text(src.title.isEmpty ? src.url : src.title)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, systemImage: String, accent: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(accent)
    }
}
