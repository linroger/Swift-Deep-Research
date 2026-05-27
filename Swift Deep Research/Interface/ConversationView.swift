import SwiftUI
import SwiftData
import MarkdownUI

/// Active-session view: the user's question(s), the agent's progress, the
/// draft synthesis, and a sticky composer at the bottom for follow-ups.
struct ConversationView: View {
    let live: LiveSession?
    let storedSession: StoredSession?
    @Binding var query: String
    let onSubmit: () -> Void
    let onFollowUp: () -> Void
    let onNewSession: () -> Void
    let onCancel: () -> Void

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if let live { liveSection(live) }
                        else if let storedSession { storedSection(storedSession) }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 880)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: live?.draftMarkdown ?? "") { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("draft", anchor: .bottom)
                    }
                }
            }

            composerDock
        }
    }

    // MARK: - Live session content

    @ViewBuilder
    private func liveSection(_ live: LiveSession) -> some View {
        sessionHeader(live: live)

        if !live.turnHistory.isEmpty {
            priorTranscript(live.turnHistory)
        }

        // User question chip
        userBubble(live.query)

        // Iteration strip when multi-round
        if live.maxRounds > 1 {
            IterationStrip(current: live.currentRound, total: live.maxRounds)
        }

        // Plan card
        if let plan = live.plan {
            PlanCard(plan: plan)
        } else if live.status == .planning {
            inflightCard(text: "Decomposing your question into research tasks…",
                        systemImage: "list.bullet.rectangle")
        }

        // Workers grid
        if !live.workers.isEmpty {
            WorkersGrid(workers: live.workers.values.sorted { $0.descriptor.id.raw < $1.descriptor.id.raw })
        }

        // Reflection
        if let critique = live.lastCritique, live.status != .complete {
            ReflectionCard(critique: critique)
        }

        // Draft
        if !live.draftMarkdown.isEmpty {
            DraftCard(markdown: live.draftMarkdown,
                     citations: live.citations,
                     sources: Array(live.fetchedSources.values),
                     discovered: live.discoveredSources)
                .id("draft")
        } else if live.status == .synthesizing {
            inflightCard(text: "Writing the synthesis…",
                        systemImage: "doc.text.fill")
        }

        // Failure
        if let failure = live.failure {
            failureBanner(failure)
        }
    }

    @ViewBuilder
    private func storedSection(_ session: StoredSession) -> some View {
        Text(session.query)
            .font(.title.weight(.bold))
            .padding(.bottom, 4)
        ForEach(session.turns.sorted(by: { $0.createdAt < $1.createdAt })) { turn in
            if turn.role == "user" {
                userBubble(turn.markdown)
            } else {
                StoredTurnCard(turn: turn)
            }
        }
    }

    // MARK: - Composer dock

    private var composerDock: some View {
        let isWorking = live.map { live in
            live.status == .planning || live.status == .working ||
            live.status == .synthesizing || live.status == .reflecting
        } ?? false
        let canFollowUp = live.map { live in
            live.status == .complete || live.status == .failed
        } ?? (storedSession != nil)

        return VStack(spacing: 0) {
            Divider().opacity(0.4)
            Composer(text: $query,
                    placeholder: canFollowUp ? "Ask a follow-up…" : "Ask a research question…",
                    isWorking: isWorking,
                    canFollowUp: canFollowUp,
                    isHero: false,
                    onSubmit: onSubmit,
                    onFollowUp: onFollowUp,
                    onNewSession: onNewSession,
                    onCancel: onCancel)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
                .environment(env)
        }
        .background(.regularMaterial)
    }

    // MARK: - Header

    private func sessionHeader(live: LiveSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(live.query)
                    .font(.title.weight(.semibold))
                    .lineLimit(3)
                Spacer()
                StatusPill(status: live.status)
            }
            HStack(spacing: 14) {
                metric("\(live.totalTokens.formatted())", "tokens", systemImage: "circle.hexagongrid.fill")
                metric("\(live.fetchedSources.count)", "fetched", systemImage: "doc.text")
                metric("\(live.citations.count)", "cited", systemImage: "quote.bubble")
                if live.maxRounds > 1 {
                    metric("\(live.currentRound)/\(live.maxRounds)", "rounds",
                          systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private func metric(_ value: String, _ label: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(value).fontWeight(.medium)
            Text(label).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Bubbles & helpers

    private func userBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.primary.opacity(0.04))
        )
    }

    private func inflightCard(text: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            ProgressView().controlSize(.small)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func failureBanner(_ failure: EngineFailure) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Research failed").font(.subheadline.weight(.semibold))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func priorTranscript(_ turns: [LiveSession.TurnRecord]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(turns) { turn in
                    if turn.role == .user {
                        userBubble(turn.query)
                    } else {
                        VStack(alignment: .leading) {
                            Label("Previous answer", systemImage: "sparkles")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Markdown(turn.markdown)
                                .markdownTheme(.gitHub)
                        }
                        .padding(12)
                        .background(.regularMaterial.opacity(0.4),
                                   in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Earlier in this conversation (\(turns.count / 2) turns)",
                  systemImage: "clock.arrow.circlepath")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Status Pill

private struct StatusPill: View {
    let status: LiveSession.Status

    var body: some View {
        HStack(spacing: 5) {
            if isInflight {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: icon)
                    .font(.caption)
            }
            Text(status.rawValue.capitalized)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.16), in: Capsule())
        .foregroundStyle(color)
    }

    private var isInflight: Bool {
        status == .planning || status == .working || status == .synthesizing || status == .reflecting
    }
    private var icon: String {
        switch status {
        case .idle: "moon.zzz"
        case .planning, .working, .synthesizing, .reflecting: "circle.dashed"
        case .complete: "checkmark.seal.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "minus.circle"
        }
    }
    private var color: Color {
        switch status {
        case .complete: .green
        case .failed: .red
        case .cancelled: .secondary
        default: .accentColor
        }
    }
}

// MARK: - Iteration Strip

private struct IterationStrip: View {
    let current: Int
    let total: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...total, id: \.self) { round in
                Capsule()
                    .fill(round <= current ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(height: 4)
            }
            Text("Round \(current)/\(total)")
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .fixedSize()
        }
    }
}

// MARK: - Stored turn

private struct StoredTurnCard: View {
    let turn: StoredTurn
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Synthesis", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Markdown(turn.markdown)
                .markdownTheme(.gitHub)
                .textSelection(.enabled)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
