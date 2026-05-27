import SwiftUI

struct WorkersGrid: View {
    let workers: [LiveSession.WorkerSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.3.fill")
                    .font(.callout)
                    .foregroundStyle(.tint)
                Text("Workers")
                    .font(.headline)
                Text("\(activeCount) active · \(completeCount) done")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                ForEach(workers) { w in
                    WorkerCard(snapshot: w)
                }
            }
        }
    }

    private var activeCount: Int { workers.filter { $0.summary == nil }.count }
    private var completeCount: Int { workers.filter { $0.summary != nil }.count }
}

struct WorkerCard: View {
    let snapshot: LiveSession.WorkerSnapshot
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusHeader
            Text(snapshot.lastMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if !snapshot.toolHistory.isEmpty {
                toolHistorySection
            }
        }
        .padding(14)
        .glassCard()
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(snapshot.summary == nil
                              ? Color.accentColor.opacity(0.25)
                              : Color.green.opacity(0.25),
                             lineWidth: 0.5)
        )
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle()
                    .fill(snapshot.summary == nil
                          ? Color.accentColor.opacity(0.20)
                          : Color.green.opacity(0.20))
                    .frame(width: 22, height: 22)
                if snapshot.summary == nil {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                }
            }
            Text(snapshot.descriptor.task)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var toolHistorySection: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(snapshot.toolHistory) { event in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: icon(for: event))
                            .font(.caption2)
                            .foregroundStyle(color(for: event))
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.invocation.name)
                                .font(.caption.weight(.medium))
                            if let outcome = event.outcome {
                                Text(summary(outcome))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("\(snapshot.toolHistory.count) tool call\(snapshot.toolHistory.count == 1 ? "" : "s")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func icon(for event: LiveSession.WorkerSnapshot.ToolEvent) -> String {
        switch event.outcome {
        case .ok: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .none: "circle.dotted"
        }
    }
    private func color(for event: LiveSession.WorkerSnapshot.ToolEvent) -> Color {
        switch event.outcome {
        case .ok: .green
        case .failed: .red
        case .none: .accentColor
        }
    }
    private func summary(_ outcome: ToolOutcome) -> String {
        switch outcome {
        case .ok(let s, _): s
        case .failed(let m): m
        }
    }
}
