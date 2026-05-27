import SwiftUI

/// Shows the orchestrator's self-critique mid-run. Renders the verdict pill,
/// remaining gaps, unsupported claims, and any suggested refinements so the
/// user can see *why* another iteration is being kicked off.
struct ReflectionCard: View {
    let critique: Reflector.Critique

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Reflection", systemImage: "brain.head.profile")
                    .font(.headline)
                Spacer()
                verdictPill
            }
            if !critique.rationale.isEmpty {
                Text(critique.rationale)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !critique.gaps.isEmpty {
                section(title: "Gaps to fill") {
                    ForEach(Array(critique.gaps.enumerated()), id: \.offset) { _, gap in
                        bullet(gap.question, secondary: gap.rationale)
                    }
                }
            }
            if !critique.unsupportedClaims.isEmpty {
                section(title: "Unsupported claims") {
                    ForEach(Array(critique.unsupportedClaims.enumerated()), id: \.offset) { _, claim in
                        bullet(claim, secondary: nil)
                    }
                }
            }
            if !critique.suggestedRefinements.isEmpty {
                section(title: "Suggested refinements") {
                    ForEach(Array(critique.suggestedRefinements.enumerated()), id: \.offset) { _, hint in
                        bullet(hint, secondary: nil)
                    }
                }
            }
        }
        .padding(16)
        .glassCard()
    }

    private var verdictPill: some View {
        let (label, color): (String, Color) = {
            switch critique.verdict {
            case .ready: return ("Ready", .green)
            case .needsMoreResearch: return ("Needs research", .orange)
            case .needsClarification: return ("Ambiguous", .yellow)
            }
        }()
        return Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func bullet(_ primary: String, secondary: String?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(primary).font(.callout)
                if let secondary, !secondary.isEmpty {
                    Text(secondary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
