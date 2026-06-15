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
                // The decision-useful headline: a probability distribution over
                // named outcome scenarios, shown above the prose report when the
                // backend produced a structured forecast (E3-forecast-2).
                if let forecast = run.structuredForecast, !forecast.scenarios.isEmpty {
                    forecastCard(forecast)
                }
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
                if run.canChat {
                    ForecastChatView(run: run)
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

    // MARK: - Structured forecast

    private func forecastCard(_ forecast: MFForecast) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Forecast", systemImage: "chart.bar.xaxis").font(.headline)
                Spacer()
                if let h = forecast.horizon, !h.isEmpty {
                    Text("Horizon \(h)").font(.caption).foregroundStyle(.secondary)
                }
                if let c = forecast.confidence, !c.isEmpty {
                    Text("\(c.capitalized) confidence")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(confidenceColor(c).opacity(0.15), in: Capsule())
                        .foregroundStyle(confidenceColor(c))
                }
            }
            ForEach(forecast.rankedScenarios) { scenario in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(scenario.name).font(.callout.weight(.medium))
                        Spacer()
                        Text("\(scenario.percent)%")
                            .font(.callout.weight(.bold)).monospacedDigit()
                            .foregroundStyle(.tint)
                    }
                    ProgressView(value: max(0, min(1, scenario.probability)))
                        .tint(.accentColor)
                    if let summary = scenario.summary, !summary.isEmpty {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let drivers = scenario.key_drivers, !drivers.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(drivers, id: \.self) { driver in
                                Text(driver)
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary.opacity(0.4), in: Capsule())
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .glassCard()
    }

    private func confidenceColor(_ confidence: String) -> Color {
        switch confidence.lowercased() {
        case "high": .green
        case "low": .orange
        default: .blue
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
                    .accessibilityLabel("Copy report")
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

// MARK: - Follow-up chat with the report agent

/// Q&A thread riding on the finished simulation: the report agent re-queries the
/// post-simulation knowledge graph (and can interview live agents) to answer.
struct ForecastChatView: View {
    let run: ForecastRun
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Ask the report agent", systemImage: "bubble.left.and.text.bubble.right")
                .font(.subheadline.weight(.semibold))
            Text("Follow-up questions are answered from the simulation's knowledge graph — why a faction flipped, what drove a sentiment spike, how confident a claim is.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(run.chatMessages) { message in
                messageRow(message)
            }

            if run.chatBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("The agent is querying the graph — this can take a minute or two…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            if let error = run.chatError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                TextField("Ask about the forecast…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                    .disabled(run.chatBusy)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(run.chatBusy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send question")
            }
        }
        .padding(14)
        .glassCard()
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !run.chatBusy else { return }
        draft = ""
        run.sendChat(text)
    }

    @ViewBuilder
    private func messageRow(_ message: ForecastRun.ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 12))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                Markdown(message.text)
                    .textSelection(.enabled)
                if !message.toolNames.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(Array(Set(message.toolNames)).sorted(), id: \.self) { tool in
                            Label(tool, systemImage: "wrench.and.screwdriver")
                                .font(.caption2)
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.cyan.opacity(0.1), in: Capsule())
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
