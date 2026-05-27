import SwiftUI

/// The query input + run controls. Used both in the welcome hero (centered,
/// large) and in active sessions (anchored bottom, compact). One component so
/// every send/cancel/follow-up surface stays in sync.
struct Composer: View {
    @Binding var text: String
    let placeholder: String
    let isWorking: Bool
    let canFollowUp: Bool
    let isHero: Bool
    let onSubmit: () -> Void
    let onFollowUp: () -> Void
    let onNewSession: () -> Void
    let onCancel: () -> Void

    @Environment(AppEnvironment.self) private var env
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var env = env
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isHero ? "sparkles" : "magnifyingglass")
                    .font(isHero ? .title2 : .body)
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeating, isActive: isWorking)
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(isHero ? .title3 : .body)
                    .lineLimit(1...6)
                    .focused($fieldFocused)
                    .onSubmit(handlePrimary)
                trailingActions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, isHero ? 14 : 10)
            .background(composerBackground)

            optionsRow
        }
        .onAppear { if isHero { fieldFocused = true } }
    }

    // MARK: - Trailing actions

    @ViewBuilder
    private var trailingActions: some View {
        if isWorking {
            Button(action: onCancel) {
                Image(systemName: "stop.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .background(.red.opacity(0.15), in: Circle())
            .foregroundStyle(.red)
            .help("Cancel research")
        } else if canFollowUp {
            HStack(spacing: 6) {
                Button(action: onNewSession) {
                    Image(systemName: "plus.circle")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Start a fresh session")
                primaryButton(label: "Follow up", icon: "arrow.up", action: onFollowUp)
            }
        } else {
            primaryButton(label: "Research", icon: "arrow.up", action: onSubmit)
        }
    }

    private func primaryButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.borderless)
        .background(canSubmit ? Color.accentColor : Color.accentColor.opacity(0.35),
                   in: Circle())
        .foregroundStyle(.white)
        .disabled(!canSubmit)
        .keyboardShortcut(.return, modifiers: .command)
        .help("\(label) (⌘↩)")
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func handlePrimary() {
        if isWorking { return }
        if canFollowUp { onFollowUp() } else { onSubmit() }
    }

    // MARK: - Options row

    private var optionsRow: some View {
        @Bindable var env = env
        return HStack(spacing: 14) {
            Toggle(isOn: $env.configuration.useKnowledgeBase) {
                Label("Knowledge base", systemImage: "books.vertical.fill")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Workers can search your uploaded documents via pyseekdb")

            Divider().frame(height: 14)

            Menu {
                ForEach(DepthPreset.allCases, id: \.self) { preset in
                    Button {
                        env.configuration.budget = preset.budget
                        env.configuration.iteration = preset.iteration
                    } label: {
                        VStack(alignment: .leading) {
                            Text(preset.title)
                            Text(preset.description).font(.caption)
                        }
                    }
                }
            } label: {
                Label(currentDepthLabel, systemImage: "gauge.with.dots.needle.50percent")
                    .font(.caption.weight(.medium))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

            Spacer(minLength: 0)

            providerSummary
        }
        .padding(.horizontal, isHero ? 8 : 4)
    }

    private var providerSummary: some View {
        let cfg = env.configuration
        return HStack(spacing: 4) {
            Image(systemName: "brain.head.profile")
                .font(.caption2)
            Text(cfg.workerProvider.displayName)
                .font(.caption2)
                .lineLimit(1)
            if let m = cfg.workerModel {
                Text("·").font(.caption2).foregroundStyle(.tertiary)
                Text(m).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .foregroundStyle(.secondary)
        .help("Worker model. Open Settings to change.")
    }

    private var currentDepthLabel: String {
        switch env.configuration.iteration.maxRounds {
        case 1: "Fast"
        case 2, 3: "Standard"
        default: "Thorough"
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var composerBackground: some View {
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: 14)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        }
    }
}

enum DepthPreset: String, CaseIterable {
    case fast, standard, thorough

    var title: String {
        switch self {
        case .fast: "Fast"
        case .standard: "Standard"
        case .thorough: "Thorough"
        }
    }
    var description: String {
        switch self {
        case .fast: "1 round, narrow budget"
        case .standard: "3 rounds with reflection"
        case .thorough: "6 rounds, deepening + cross-verify"
        }
    }
    var budget: AgentBudget {
        switch self {
        case .fast: .fast
        case .standard: .standard
        case .thorough: .thorough
        }
    }
    var iteration: IterationController {
        switch self {
        case .fast: .fast
        case .standard: .standard
        case .thorough: .thorough
        }
    }
}
