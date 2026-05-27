import SwiftUI

/// Spotlight-style hero shown when no session is selected or running. The
/// composer is the focal point. Suggested queries reduce the cold-start
/// problem of "what should I even ask?".
struct WelcomeView: View {
    @Binding var query: String
    let canFollowUp: Bool
    let isWorking: Bool
    let onSubmit: () -> Void
    let onFollowUp: () -> Void
    let onNewSession: () -> Void
    let onCancel: () -> Void

    @Environment(AppEnvironment.self) private var env

    private let suggestions: [String] = [
        "What are the most important AI papers published this month?",
        "Compare Anthropic Claude 4.7 and OpenAI gpt-5.5 on coding benchmarks.",
        "Latest research on multi-agent orchestration patterns.",
        "How does pyseekdb compare to ChromaDB and Qdrant for local RAG?",
        "What did Apple announce at WWDC 2026 about Foundation Models?",
        "Summarize the state of macOS 26 Liquid Glass adoption."
    ]

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: max(40, proxy.size.height * 0.10))
                centerStack
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 32)
        }
    }

    private var centerStack: some View {
        VStack(spacing: 28) {
            heroHeader
            Composer(text: $query,
                    placeholder: "Ask anything…",
                    isWorking: isWorking,
                    canFollowUp: canFollowUp,
                    isHero: true,
                    onSubmit: onSubmit,
                    onFollowUp: onFollowUp,
                    onNewSession: onNewSession,
                    onCancel: onCancel)
                .environment(env)
            suggestionStrip
        }
    }

    private var heroHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.linearGradient(
                    colors: [.accentColor, .accentColor.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom))
                .padding(.bottom, 4)
            Text("Deep Research")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Decompose a question, dispatch parallel sub-agents, and synthesize a cited answer.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var suggestionStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try one of these")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.leading, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)],
                     alignment: .leading,
                     spacing: 10) {
                ForEach(suggestions, id: \.self) { suggestion in
                    SuggestionChip(text: suggestion) {
                        query = suggestion
                        onSubmit()
                    }
                }
            }
        }
    }
}

private struct SuggestionChip: View {
    let text: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
                Text(text)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(hovered ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(hovered ? 0.12 : 0.06), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
