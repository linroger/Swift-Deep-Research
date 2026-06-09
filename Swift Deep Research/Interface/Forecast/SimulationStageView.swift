import SwiftUI
import Charts

/// Stage 5 panel: the live OASIS multi-agent social simulation. Shows the round
/// progress, per-platform (Twitter / Reddit) status and action counts, a
/// per-round activity chart, and a feed of the most recent agent actions.
struct SimulationStageView: View {
    let run: ForecastRun

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if run.runState == nil && run.recentActions.isEmpty {
                    pending
                } else {
                    roundHeader
                    platformCards
                    if !run.timeline.isEmpty { activityChart }
                    if !run.recentActions.isEmpty { actionFeed }
                }
            }
            .padding(16)
        }
    }

    private var pending: some View {
        ContentUnavailableView {
            Label("Simulation pending", systemImage: "waveform.path.ecg")
        } description: {
            Text("Once the knowledge graph is built, MiroFish turns the actors into LLM agents and runs them on simulated Twitter + Reddit. Their behaviour streams here.")
        }
    }

    // MARK: - Round header

    private var roundHeader: some View {
        let s = run.runState
        let current = s?.current_round ?? 0
        let total = max(s?.total_rounds ?? 0, 1)
        let pct = min(Double(current) / Double(total), 1.0)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Round \(current) / \(s?.total_rounds ?? 0)", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                if let hours = s?.simulated_hours, let total = s?.total_simulation_hours, total > 0 {
                    Text("\(hours)h / \(total)h simulated")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: pct)
                .tint(.purple)
            HStack(spacing: 16) {
                metric("Total actions", value: s?.total_actions_count ?? 0, color: .purple)
                metric("Twitter", value: s?.twitter_actions_count ?? 0, color: .blue)
                metric("Reddit", value: s?.reddit_actions_count ?? 0, color: .orange)
            }
        }
        .padding(14)
        .glassCard()
    }

    private func metric(_ label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Platforms

    private var platformCards: some View {
        HStack(spacing: 12) {
            platformCard(name: "Twitter", systemImage: "bird",
                         running: run.runState?.twitter_running ?? false,
                         completed: run.runState?.twitter_completed ?? false,
                         round: run.runState?.twitter_current_round ?? 0,
                         actions: run.runState?.twitter_actions_count ?? 0,
                         accent: .blue)
            platformCard(name: "Reddit", systemImage: "person.2.wave.2",
                         running: run.runState?.reddit_running ?? false,
                         completed: run.runState?.reddit_completed ?? false,
                         round: run.runState?.reddit_current_round ?? 0,
                         actions: run.runState?.reddit_actions_count ?? 0,
                         accent: .orange)
        }
    }

    private func platformCard(name: String, systemImage: String, running: Bool, completed: Bool,
                              round: Int, actions: Int, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(name, systemImage: systemImage).font(.subheadline.weight(.semibold))
                Spacer()
                statusDot(running: running, completed: completed)
            }
            Text("Round \(round)").font(.caption).foregroundStyle(.secondary)
            Text("\(actions) actions").font(.caption).foregroundStyle(accent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(accent.opacity(0.2)))
    }

    private func statusDot(running: Bool, completed: Bool) -> some View {
        let (color, text): (Color, String) =
            completed ? (.green, "done") : (running ? (.blue, "running") : (.gray, "idle"))
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Activity chart

    private var activityChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Actions per round").font(.subheadline.weight(.semibold))
            Chart(run.timeline) { entry in
                BarMark(
                    x: .value("Round", entry.round_num),
                    y: .value("Twitter", entry.twitter_actions ?? 0)
                )
                .foregroundStyle(by: .value("Platform", "Twitter"))
                BarMark(
                    x: .value("Round", entry.round_num),
                    y: .value("Reddit", entry.reddit_actions ?? 0)
                )
                .foregroundStyle(by: .value("Platform", "Reddit"))
            }
            .chartForegroundStyleScale(["Twitter": Color.blue, "Reddit": Color.orange])
            .frame(height: 160)
        }
        .padding(14)
        .glassCard()
    }

    // MARK: - Action feed

    private var actionFeed: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Latest agent actions").font(.subheadline.weight(.semibold))
            ForEach(run.recentActions.prefix(40)) { action in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: platformIcon(action.platform))
                        .font(.caption)
                        .foregroundStyle(action.platform == "reddit" ? .orange : .blue)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(action.agent_name ?? "Agent \(action.agent_id ?? 0)")
                                .font(.caption.weight(.semibold))
                            Text(actionLabel(action.action_type))
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                        if let result = action.result, !result.isEmpty {
                            Text(result).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if let r = action.round_num {
                        Text("r\(r)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func platformIcon(_ platform: String?) -> String {
        platform == "reddit" ? "person.2.wave.2" : "bird"
    }

    private func actionLabel(_ raw: String?) -> String {
        (raw ?? "ACTION").replacingOccurrences(of: "_", with: " ").lowercased()
    }
}
