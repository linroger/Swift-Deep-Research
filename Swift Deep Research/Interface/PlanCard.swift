import SwiftUI

struct PlanCard: View {
    let plan: ResearchPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(plan.restatement)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(plan.subtasks.enumerated()), id: \.element.id) { idx, subtask in
                    subtaskRow(index: idx + 1, subtask: subtask)
                }
            }
        }
        .padding(18)
        .glassCard()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.callout)
                .foregroundStyle(.tint)
            Text("Research plan")
                .font(.headline)
            Spacer()
            strategyBadge(plan.strategy.rawValue)
            complexityBadge(plan.estimatedComplexity.rawValue)
        }
    }

    private func subtaskRow(index: Int, subtask: ResearchPlan.Subtask) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 22, height: 22)
                Text("\(index)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(subtask.question)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtask.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func strategyBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(.tint)
    }

    private func complexityBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
    }
}
