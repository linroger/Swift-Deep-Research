import SwiftUI

/// Spotlight-style hero for starting a forecast. One prompt, a depth + mode
/// choice, and an optional round cap → the whole DeerFlow × MiroFish pipeline.
struct ForecastComposer: View {
    @Environment(AppEnvironment.self) private var env

    @State private var prompt: String = ""
    @State private var depth: String = "standard"
    @State private var mode: ForecastRun.Mode = .full
    @State private var maxRoundsText: String = ""
    @FocusState private var promptFocused: Bool

    private let depths = ["quick", "standard", "deep"]
    private let suggestions: [String] = [
        "If a major city fully deregulates ride-hailing permits, how will local taxi-driver sentiment evolve over three months?",
        "How will public opinion react if a leading AI lab open-sources its frontier model?",
        "Predict the community response to a new campus free-speech policy at a large university.",
        "How would markets and retail investors react to a surprise central-bank rate cut?"
    ]

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: max(32, proxy.size.height * 0.06))
                    center.frame(maxWidth: 760).frame(maxWidth: .infinity)
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 32)
                .frame(minHeight: proxy.size.height)
            }
        }
        .onAppear {
            promptFocused = true
            depth = env.forecastConfig.defaultDepth
        }
    }

    private var center: some View {
        VStack(spacing: 24) {
            hero
            ForecastBackendBanner()
            composerCard
            suggestionStrip
        }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.linearGradient(
                    colors: [.purple, .blue.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                .padding(.bottom, 4)
            Text("Forecast")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Deep-research a question, build a knowledge graph, run thousands of LLM agents on a simulated society, and read the prediction back out.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Prompt
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("What do you want to predict?")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8).padding(.leading, 5)
                }
                TextEditor(text: $prompt)
                    .focused($promptFocused)
                    .font(.title3)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 72, maxHeight: 160)
            }

            Divider()

            // Options row
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Research depth").font(.caption2).foregroundStyle(.secondary)
                    Picker("", selection: $depth) {
                        ForEach(depths, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mode").font(.caption2).foregroundStyle(.secondary)
                    Picker("", selection: $mode) {
                        Text("Full forecast").tag(ForecastRun.Mode.full)
                        Text("Research only").tag(ForecastRun.Mode.research_only)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
                if mode == .full {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Max rounds").font(.caption2).foregroundStyle(.secondary)
                        TextField("auto", text: $maxRoundsText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                }
                Spacer()
                Button(action: run) {
                    Label("Run forecast", systemImage: "play.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .glassCard()
    }

    private var suggestionStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try one of these")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.leading, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        prompt = suggestion
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "sparkle")
                                .font(.caption2.weight(.bold)).foregroundStyle(.purple).padding(.top, 2)
                            Text(suggestion).font(.callout).multilineTextAlignment(.leading)
                                .lineLimit(3).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func run() {
        let q = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let rounds = Int(maxRoundsText.trimmingCharacters(in: .whitespaces))
        env.startForecast(prompt: q, mode: mode, depth: depth, maxRounds: rounds)
    }
}

/// Live status of the MiroFish backend, with actionable guidance when it isn't
/// ready. Surfaces the supervisor's `Status` so a forecast never fails opaquely.
struct ForecastBackendBanner: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            switch env.forecastBackendStatus {
            case .running:
                banner(icon: "checkmark.seal.fill", tint: .green,
                       title: "MiroFish backend ready",
                       message: "Connected at \(env.forecastConfig.hostString).")
            case .launching:
                banner(icon: "hourglass", tint: .blue,
                       title: "Starting MiroFish backend…",
                       message: "Loading the prediction engine (this can take a minute on first launch).",
                       showsSpinner: true)
            case .stopped:
                banner(icon: "bolt.horizontal.circle", tint: .secondary,
                       title: "MiroFish backend not started",
                       message: "It will start automatically when you run a forecast, or check Settings → Forecast.")
            case .backendMissing(let m), .interpreterMissing(let m), .failed(let m):
                banner(icon: "exclamationmark.triangle.fill", tint: .orange,
                       title: "MiroFish backend needs setup",
                       message: m, showsSetup: true)
            }
        }
    }

    private func banner(icon: String, tint: Color, title: String, message: String,
                        showsSpinner: Bool = false, showsSetup: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if showsSpinner {
                ProgressView().controlSize(.small).frame(width: 20)
            } else {
                Image(systemName: icon).foregroundStyle(tint).font(.title3).frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if showsSetup {
                Button("Set up…") { env.forecastOnboardingOpen = true }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Settings") { env.settingsOpen = true }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
    }
}
