import SwiftUI

/// First-run setup assistant for the Forecast workspace. Walks through:
/// environment checks → Zep key → `setup.sh` (live console) → backend launch.
/// Presented as a sheet from the workspace, the backend banner, or Settings.
struct ForecastOnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var onboarding: ForecastOnboarding?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let onboarding {
                content(onboarding)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 620)
        .task {
            let model = ForecastOnboarding(config: env.forecastConfig)
            onboarding = model
            await model.refreshChecks()
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.linearGradient(colors: [.purple, .blue.opacity(0.6)],
                                                 startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 2) {
                Text("Set up Forecast").font(.title3.weight(.bold))
                Text("One-time setup: install the MiroFish prediction engine's dependencies and start the backend.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if let onboarding, case .running = onboarding.setupPhase {
                Button("Cancel setup", role: .destructive) { onboarding.cancelSetup() }
                    .controlSize(.small)
            }
            Spacer()
            Button(doneIsPrimary ? "Done" : "Close") { finish() }
                .keyboardShortcut(doneIsPrimary ? .defaultAction : .cancelAction)
                .buttonStyle(doneIsPrimary ? AnyPrimitiveButtonStyle(.borderedProminent)
                                           : AnyPrimitiveButtonStyle(.bordered))
        }
        .padding(12)
    }

    private var doneIsPrimary: Bool {
        if let onboarding, onboarding.completed { return true }
        return false
    }

    private func finish() {
        onboarding?.cancelSetup()
        if onboarding?.completed == true { env.forecastBackendStatus = .running }
        dismiss()
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ onboarding: ForecastOnboarding) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    checksSection(onboarding)
                    zepSection(onboarding)
                    setupSection(onboarding)
                    launchSection(onboarding)
                }
                .padding(16)
            }
            .onChange(of: onboarding.consoleLines.count) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("console-tail", anchor: .bottom)
                }
            }
        }
    }

    // MARK: Step 1 — environment checks

    private func checksSection(_ onboarding: ForecastOnboarding) -> some View {
        stepCard(number: 1, title: "Check this Mac",
                 subtitle: "What the forecast pipeline needs on this machine.") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(onboarding.checks) { check in
                    HStack(alignment: .top, spacing: 8) {
                        checkIcon(check.state)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.title).font(.callout.weight(.medium))
                            Text(check.detail).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
                HStack {
                    Spacer()
                    if onboarding.checking { ProgressView().controlSize(.mini) }
                    Button("Re-check") { Task { await onboarding.refreshChecks() } }
                        .controlSize(.small)
                        .disabled(onboarding.checking)
                }
            }
        }
    }

    @ViewBuilder
    private func checkIcon(_ state: ForecastOnboarding.CheckState) -> some View {
        switch state {
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    // MARK: Step 2 — Zep key

    private func zepSection(_ onboarding: ForecastOnboarding) -> some View {
        stepCard(number: 2, title: "Zep Cloud API key",
                 subtitle: "Stores the knowledge graph. Free tier works — app.getzep.com.") {
            @Bindable var onboarding = onboarding
            VStack(alignment: .leading, spacing: 8) {
                if onboarding.zepConfigured {
                    Label("Key configured — it syncs into MiroFish's .env automatically.",
                          systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                HStack(spacing: 8) {
                    SecureField(onboarding.zepConfigured ? "Replace key (optional)" : "z_…",
                                text: $onboarding.zepKeyInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { Task { await onboarding.saveZepKey() } }
                        .controlSize(.small)
                        .disabled(onboarding.zepKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let message = onboarding.zepSaveMessage {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Step 3 — setup script

    private func setupSection(_ onboarding: ForecastOnboarding) -> some View {
        stepCard(number: 3, title: "Install dependencies",
                 subtitle: "Runs MiroFish's setup.sh: backend venv (Python 3.12), DeerFlow research engine + patches. Idempotent — safe to re-run. First run takes several minutes.") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    switch onboarding.setupPhase {
                    case .idle:
                        if onboarding.looksProvisioned {
                            Label("Everything looks installed already — you can skip this.",
                                  systemImage: "checkmark.seal.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                    case .running:
                        ProgressView().controlSize(.small)
                        Text("Running setup…").font(.caption).foregroundStyle(.secondary)
                    case .succeeded:
                        Label("Setup finished.", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(.green)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(setupButtonTitle(onboarding)) { onboarding.runSetup() }
                        .controlSize(.small)
                        .disabled(!onboarding.canRunSetup || onboarding.setupPhase == .running)
                }
                if !onboarding.canRunSetup {
                    Text("Fix the red items in step 1 first (MiroFish folder and uv are required).")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if !onboarding.consoleLines.isEmpty {
                    console(onboarding)
                }
            }
        }
    }

    private func setupButtonTitle(_ onboarding: ForecastOnboarding) -> String {
        switch onboarding.setupPhase {
        case .running: "Running…"
        case .succeeded: "Run again"
        case .failed: "Retry"
        case .idle: onboarding.looksProvisioned ? "Run anyway" : "Run setup"
        }
    }

    private func console(_ onboarding: ForecastOnboarding) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(onboarding.consoleLines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Color.clear.frame(height: 1).id("console-tail")
            }
            .padding(8)
            .textSelection(.enabled)
        }
        .frame(height: 180)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Step 4 — launch

    private func launchSection(_ onboarding: ForecastOnboarding) -> some View {
        stepCard(number: 4, title: "Start the backend",
                 subtitle: "Launches MiroFish on \(env.forecastConfig.hostString) and waits for it to answer. Cold start takes up to a minute.") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    statusLabel(onboarding)
                    Spacer()
                    Button(onboarding.completed ? "Running ✓" : "Start backend") {
                        Task {
                            let status = await onboarding.startBackend()
                            env.forecastBackendStatus = status
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(onboarding.launching || onboarding.completed)
                }
            }
        }
    }

    @ViewBuilder
    private func statusLabel(_ onboarding: ForecastOnboarding) -> some View {
        if onboarding.launching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting — importing the simulation stack…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            switch onboarding.backendStatus {
            case .running:
                Label("Backend is running — you're ready to forecast.", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            case .stopped:
                Text("Not started yet.").font(.caption).foregroundStyle(.secondary)
            case .launching:
                Text("Still starting…").font(.caption).foregroundStyle(.secondary)
            case .backendMissing(let m), .interpreterMissing(let m), .failed(let m):
                Label(m, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Card chrome

    private func stepCard(number: Int, title: String, subtitle: String,
                          @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number)")
                    .font(.caption.weight(.bold)).monospacedDigit()
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.accentColor.opacity(0.18)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
                .padding(.leading, 28)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

/// Type-erasing wrapper so the footer button can switch between bordered and
/// prominent styles in a single expression.
private struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let _makeBody: (Configuration) -> AnyView
    init(_ style: some PrimitiveButtonStyle) {
        _makeBody = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View {
        _makeBody(configuration)
    }
}
