import SwiftUI
import SwiftData

/// Sidebar list of past forecasts (shown when the workspace is in Forecast mode).
struct ForecastSidebar: View {
    let records: [ForecastRecord]
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List(selection: Binding(
            get: { env.forecast?.pipelineID },
            set: { _ in }
        )) {
            Section {
                Button {
                    env.newForecast()
                } label: {
                    Label("New forecast", systemImage: "plus.circle.fill")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }

            if records.isEmpty && remotePipelines.isEmpty {
                ContentUnavailableView {
                    Label("No forecasts yet", systemImage: "chart.line.uptrend.xyaxis")
                } description: {
                    Text("Run a forecast to predict how a society reacts to an event.")
                }
                .listRowSeparator(.hidden)
            }
            if !records.isEmpty {
                Section("Forecasts") {
                    ForEach(records) { record in
                        ForecastSidebarRow(record: record,
                                           isActive: env.forecast?.pipelineID == record.pipelineID)
                            .contentShape(Rectangle())
                            .onTapGesture { env.openForecast(record: record) }
                            .contextMenu {
                                Button(role: .destructive) {
                                    delete(record)
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                }
            }
            if !remotePipelines.isEmpty {
                Section {
                    ForEach(remotePipelines) { summary in
                        BackendPipelineRow(summary: summary)
                            .contentShape(Rectangle())
                            .onTapGesture { env.openBackendPipeline(summary) }
                            .contextMenu {
                                Button {
                                    env.openBackendPipeline(summary)
                                } label: { Label("Open", systemImage: "square.and.arrow.down") }
                                Button(role: .destructive) {
                                    env.deleteBackendPipeline(summary)
                                } label: { Label("Delete from backend", systemImage: "trash") }
                            }
                    }
                } header: {
                    HStack {
                        Text("On backend")
                        Spacer()
                        if env.backendPipelinesRefreshing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Button {
                                Task { await env.refreshBackendPipelines() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Refresh the pipeline list from MiroFish")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .task { await env.refreshBackendPipelines() }
    }

    /// Backend pipelines that haven't been imported locally yet — forecasts
    /// started from the MiroFish web UI, run_simulation.py, or another machine.
    private var remotePipelines: [MFPipelineSummary] {
        let known = Set(records.map(\.pipelineID))
        return env.backendPipelines.filter { !known.contains($0.pipeline_id) }
    }

    private func delete(_ record: ForecastRecord) {
        // Routes through AppEnvironment so the backend pipeline record (and its
        // handoff artifacts) is removed too, not just the local row.
        env.deleteForecast(record: record)
    }
}

/// A pipeline that exists on the MiroFish backend but hasn't been opened in
/// this app yet. Tapping imports it and opens the full multi-stage view.
private struct BackendPipelineRow: View {
    let summary: MFPipelineSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                Text(summary.prompt.isEmpty ? summary.pipeline_id : summary.prompt)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(statusLabel).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if summary.status == "running" || summary.status == "pending" {
                    Text("\(summary.global_progress)%")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch summary.status {
        case "completed": .green
        case "failed": .red
        case "cancelled": .orange
        default: .blue
        }
    }

    private var statusLabel: String {
        switch summary.status {
        case "completed": "Complete"
        case "failed": "Failed"
        case "cancelled": "Cancelled"
        case "pending": "Queued"
        default: "Running"
        }
    }
}

private struct ForecastSidebarRow: View {
    let record: ForecastRecord
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.titleSummary)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                statusDot
                Text(statusLabel).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if record.status == "running" {
                    Text("\(record.globalProgress)%")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusDot: some View {
        Circle().fill(statusColor).frame(width: 6, height: 6)
    }

    private var statusColor: Color {
        switch record.status {
        case "completed": .green
        case "failed": .red
        case "cancelled": .orange
        default: .blue
        }
    }

    private var statusLabel: String {
        switch record.status {
        case "completed": "Complete"
        case "failed": "Failed"
        case "cancelled": "Cancelled"
        default: "Running"
        }
    }
}
