import SwiftUI
import SwiftData

/// Sidebar list of past forecasts (shown when the workspace is in Forecast mode).
struct ForecastSidebar: View {
    let records: [ForecastRecord]
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var modelContext

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

            if records.isEmpty {
                ContentUnavailableView {
                    Label("No forecasts yet", systemImage: "chart.line.uptrend.xyaxis")
                } description: {
                    Text("Run a forecast to predict how a society reacts to an event.")
                }
                .listRowSeparator(.hidden)
            } else {
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
        }
        .listStyle(.sidebar)
    }

    private func delete(_ record: ForecastRecord) {
        if env.forecast?.pipelineID == record.pipelineID { env.newForecast() }
        modelContext.delete(record)
        try? modelContext.save()
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
