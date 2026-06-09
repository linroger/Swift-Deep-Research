import SwiftUI
import MarkdownUI

/// Stage 6 panel: the prediction report. Shows generation progress, the report
/// outline, the full markdown report, and the live ReAct agent log (the report
/// agent's reasoning + tool calls).
struct ForecastReportView: View {
    let run: ForecastRun

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let progress = run.reportProgress, run.report?.markdown_content?.isEmpty != false {
                    progressView(progress)
                }
                if let report = run.report, let md = report.markdown_content, !md.isEmpty {
                    reportBody(report, markdown: md)
                } else if run.report == nil && run.reportProgress == nil {
                    pending
                }
                if !run.agentLog.isEmpty {
                    agentLogView
                }
            }
            .padding(16)
        }
    }

    private var pending: some View {
        ContentUnavailableView {
            Label("Report pending", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("After the simulation runs, a ReAct agent mines the post-simulation knowledge graph — interviewing agents and running multi-hop retrievals — to write the forecast.")
        }
    }

    // MARK: - Progress

    private func progressView(_ progress: MFReportProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView().controlSize(.small)
                Text(progress.message ?? "Writing report…").font(.headline)
                Spacer()
                if let p = progress.progress { Text("\(p)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if let current = progress.current_section, !current.isEmpty {
                Text("Current section: \(current)").font(.caption).foregroundStyle(.secondary)
            }
            if let done = progress.completed_sections, !done.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(done, id: \.self) { section in
                        Label(section, systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.1), in: Capsule())
                    }
                }
            }
        }
        .padding(14)
        .glassCard()
    }

    // MARK: - Report body

    private func reportBody(_ report: MFReport, markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Prediction report", systemImage: "doc.text.fill").font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            if let outline = report.outline {
                outlineView(outline)
            }
            Markdown(markdown)
                .textSelection(.enabled)
        }
        .padding(16)
        .glassCard()
    }

    private func outlineView(_ outline: MFOutline) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = outline.title, !title.isEmpty {
                Text(title).font(.title3.weight(.bold))
            }
            if let summary = outline.summary, !summary.isEmpty {
                Text(summary).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let sections = outline.sections, !sections.isEmpty {
                Divider().padding(.vertical, 2)
                ForEach(Array(sections.enumerated()), id: \.offset) { idx, section in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(idx + 1).").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        Text(section.title ?? "Section \(idx + 1)").font(.caption.weight(.medium))
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - ReAct agent log

    private var agentLogView: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(run.agentLog) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: iconFor(entry.action))
                            .font(.caption2)
                            .foregroundStyle(colorFor(entry.action))
                            .frame(width: 14)
                        Text(entry.summary)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Agent reasoning (\(run.agentLog.count))", systemImage: "brain")
                .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .glassCard()
    }

    private func iconFor(_ action: String?) -> String {
        switch action ?? "" {
        case let a where a.contains("tool"): "wrench.and.screwdriver"
        case let a where a.contains("thought") || a.contains("react"): "brain"
        case let a where a.contains("section") && a.contains("complete"): "checkmark.circle"
        case let a where a.contains("planning"): "list.bullet.clipboard"
        default: "circle.dotted"
        }
    }

    private func colorFor(_ action: String?) -> Color {
        switch action ?? "" {
        case let a where a.contains("tool"): .cyan
        case let a where a.contains("complete"): .green
        case let a where a.contains("error"): .red
        default: .secondary
        }
    }
}
