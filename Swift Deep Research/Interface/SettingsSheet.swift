import SwiftUI
import AppKit

/// macOS System Settings-style preferences. Sidebar of section icons on the
/// left, content on the right. No redundant Done button at the bottom —
/// the standard ⌘W / red traffic light close the sheet.
struct SettingsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .providers
    /// Pending debounced configuration save. EngineConfiguration is an Equatable
    /// value type, so every keystroke in the Instructions editor and every Stepper
    /// tick mutates it and fires onChange. Coalescing the writes here avoids a
    /// synchronous JSONEncoder().encode + UserDefaults write per keystroke on the
    /// MainActor. (settings-persist-every-keystroke)
    @State private var saveTask: Task<Void, Never>?

    enum Section: String, CaseIterable, Identifiable {
        case providers, apiKeys, knowledge, forecast, budget, iteration, instructions, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .providers: "Providers"
            case .apiKeys: "API keys"
            case .knowledge: "Knowledge base"
            case .forecast: "Forecast"
            case .budget: "Budget"
            case .iteration: "Iteration"
            case .instructions: "Instructions"
            case .about: "About"
            }
        }
        var systemImage: String {
            switch self {
            case .providers: "cpu"
            case .apiKeys: "key.fill"
            case .knowledge: "books.vertical.fill"
            case .forecast: "chart.line.uptrend.xyaxis"
            case .budget: "gauge.with.dots.needle.50percent"
            case .iteration: "arrow.triangle.2.circlepath"
            case .instructions: "text.alignleft"
            case .about: "info.circle"
            }
        }
        var tint: Color {
            switch self {
            case .providers: .blue
            case .apiKeys: .yellow
            case .knowledge: .indigo
            case .forecast: .purple
            case .budget: .green
            case .iteration: .purple
            case .instructions: .pink
            case .about: .gray
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                detailHeader
                Divider().opacity(0.6)
                detail
                Divider().opacity(0.6)
                footer
            }
        }
        .frame(minWidth: 920, idealWidth: 980, minHeight: 640, idealHeight: 720)
        .onChange(of: env.configuration) { _, _ in
            // Debounce: cancel any pending save and re-arm. Persist provider/
            // model/endpoint/budget choices ~500ms after the last edit so a burst
            // of keystrokes / Stepper ticks collapses into one encode+write.
            scheduleConfigurationSave()
        }
        .onDisappear {
            // Flush immediately when the sheet closes so the last edits aren't
            // lost if dismissal beats the debounce interval.
            saveTask?.cancel()
            saveTask = nil
            env.saveConfiguration()
        }
    }

    /// Coalesce configuration persistence: replace the in-flight debounce Task so
    /// only the final state after an idle gap is written. The sleep is cancellation-
    /// aware, so a superseding edit (or sheet dismissal) skips the stale write.
    private func scheduleConfigurationSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            env.saveConfiguration()
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            iconBadge(systemImage: section.systemImage,
                     color: section.tint,
                     size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(section.title)
                    .font(.title3.weight(.semibold))
                Text(subtitle(for: section))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.regularMaterial.opacity(0.4))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.title2.weight(.bold))
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Section.allCases) { item in
                        sidebarRow(item)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 230)
        .background(.regularMaterial.opacity(0.6))
    }

    private func sidebarRow(_ item: Section) -> some View {
        Button {
            section = item
        } label: {
            HStack(spacing: 10) {
                iconBadge(systemImage: item.systemImage, color: item.tint, size: 22)
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(section == item
                          ? Color.accentColor.opacity(0.18)
                          : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconBadge(systemImage: String, color: Color, size: CGFloat = 22) -> some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            content
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func subtitle(for s: Section) -> String {
        switch s {
        case .providers: "Pick the LLMs behind research and forecasts, and the research flow."
        case .apiKeys: "Keys are stored in Keychain — never on disk."
        case .knowledge: "Connect to the local pyseekdb sidecar."
        case .forecast: "The MiroFish prediction backend for forecasts."
        case .budget: "Hard caps on tokens, workers, sources, and wall-clock."
        case .iteration: "How many reflection rounds each run gets."
        case .instructions: "House-style guidance appended to every prompt."
        case .about: "Build info and architecture overview."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .providers: ProvidersTab().environment(env)
        case .apiKeys: APIKeysTab()
        case .knowledge: KnowledgeTab().environment(env)
        case .forecast: ForecastTab().environment(env)
        case .budget: BudgetTab().environment(env)
        case .iteration: IterationTab().environment(env)
        case .instructions: InstructionsTab().environment(env)
        case .about: AboutTab()
        }
    }
}

// MARK: - Reusable section card

private struct SettingsGroup<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.leading, 12)
            }
            VStack(spacing: 0) { content }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.background.secondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let label: String
    let icon: String?
    @ViewBuilder var content: Content

    init(_ label: String, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(label)
                .font(.body)
            Spacer()
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.4)
        }
    }
}

// MARK: - Providers

/// Persists live model-discovery results across Settings sheet open/close (and
/// tab switches, which destroy `ProvidersTab`). Keyed by provider rawValue and
/// stamped with a fetch date so the discovered catalogue survives without a
/// re-test, while the curated static list stays the offline fallback.
/// (discovered-models-lost-1, providers-discovery-state-lost-on-close)
private enum DiscoveredModelsStore {
    private static let key = "providerDiscoveredModels.v1"

    private struct Entry: Codable {
        var models: [String]
        var fetchedAt: Date
    }

    /// Load the persisted per-provider discovered lists into a typed dictionary.
    static func load() -> [ProviderRegistry.ProviderID: [String]] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        var out: [ProviderRegistry.ProviderID: [String]] = [:]
        for (k, v) in raw {
            if let id = ProviderRegistry.ProviderID(rawValue: k), !v.models.isEmpty {
                out[id] = v.models
            }
        }
        return out
    }

    /// Persist (or overwrite) one provider's discovered models with a fresh stamp.
    static func save(_ models: [String], for provider: ProviderRegistry.ProviderID) {
        guard !models.isEmpty else { return }
        var raw: [String: Entry] = [:]
        if let data = UserDefaults.standard.data(forKey: key),
           let existing = try? JSONDecoder().decode([String: Entry].self, from: data) {
            raw = existing
        }
        raw[provider.rawValue] = Entry(models: models, fetchedAt: Date())
        if let encoded = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
}

/// Discovery / key-test status shared by the providers tab and its extracted
/// host-endpoint cards. File-scoped (rather than nested in `ProvidersTab`) so the
/// `HostEndpointCard` / `DiscoveryStatusLabel` subviews can reference it.
private enum OllamaFetchState: Equatable { case idle, loading, ok, error(String) }

private struct ProvidersTab: View {
    @Environment(AppEnvironment.self) private var env
    @State private var ollamaModels: [String] = []
    @State private var ollamaState: OllamaFetchState = .idle
    /// Live model-discovery results per provider (Anthropic/OpenAI/Gemini model
    /// APIs, OpenAI-compatible `/v1/models`, LM Studio / custom endpoints).
    @State private var discovered: [ProviderRegistry.ProviderID: [String]] = [:]
    /// Per-provider discovery / key-test status.
    @State private var discoveryStates: [ProviderRegistry.ProviderID: OllamaFetchState] = [:]
    @State private var lmStudioHostString: String = ""
    @State private var customHostString: String = ""
    @State private var qwenHostString: String = ""

    var body: some View {
        @Bindable var env = env
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup("Deep research flow",
                         footer: env.configuration.researchFlow.blurb) {
                SettingsRow("Methodology", icon: "arrow.triangle.branch") {
                    Picker("", selection: $env.configuration.researchFlow) {
                        ForEach(ResearchFlow.allCases) { flow in
                            Text(flow.displayName).tag(flow)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }
            }
            roleGroup(
                title: "Orchestrator",
                subtitle: "Decomposes the user's query into sub-tasks.",
                provider: $env.configuration.orchestratorProvider,
                model: $env.configuration.orchestratorModel
            )
            roleGroup(
                title: "Workers",
                subtitle: "Run sub-tasks in parallel with tool calling.",
                provider: $env.configuration.workerProvider,
                model: $env.configuration.workerModel
            )
            roleGroup(
                title: "Synthesizer",
                subtitle: "Writes the final markdown answer with citations.",
                provider: $env.configuration.synthesisProvider,
                model: $env.configuration.synthesisModel
            )
            forecastRoleGroup
            if usesOllama { ollamaCard }
            if uses(.lmstudio) { lmStudioCard }
            if uses(.custom) { customCard }
            if uses(.qwen) { qwenCard }
        }
        .task(id: env.configuration.ollamaHost) {
            if usesOllama { await fetchOllamaModels() }
        }
        .onAppear {
            lmStudioHostString = env.configuration.lmStudioHost.absoluteString
            customHostString = env.configuration.customEndpointBaseURL?.absoluteString ?? ""
            qwenHostString = env.configuration.qwenBaseURL.absoluteString
            // Re-hydrate previously discovered model lists so reopening Settings
            // (or switching tabs, which destroys this view) doesn't revert to the
            // static catalogue until the user re-tests each provider. Don't clobber
            // a list discovered earlier this session.
            if discovered.isEmpty { discovered = DiscoveredModelsStore.load() }
        }
        .onChange(of: env.configuration.orchestratorProvider) { _, _ in
            Task { if usesOllama { await fetchOllamaModels() } }
        }
        .onChange(of: env.configuration.workerProvider) { _, _ in
            Task { if usesOllama { await fetchOllamaModels() } }
        }
        .onChange(of: env.configuration.synthesisProvider) { _, _ in
            Task { if usesOllama { await fetchOllamaModels() } }
        }
    }

    /// The unified forecast role: which provider the MiroFish backend uses for
    /// DeerFlow research, the simulation agents, and the report. Pushed to the
    /// backend automatically whenever it starts; "Apply now" pushes immediately.
    private var forecastRoleGroup: some View {
        let providerBinding = Binding<ProviderRegistry.ProviderID>(
            get: { env.modelProviders.forecastAssignment.provider },
            set: { newValue in
                env.modelProviders.forecastAssignment.provider = newValue
                env.modelProviders.save()
            }
        )
        let modelBinding = Binding<String?>(
            get: { env.modelProviders.forecastAssignment.model },
            set: { newValue in
                env.modelProviders.forecastAssignment.model = newValue
                env.modelProviders.save()
            }
        )
        return VStack(alignment: .leading, spacing: 6) {
            roleGroup(
                title: ModelRole.forecast.title,
                subtitle: ModelRole.forecast.subtitle + " Applied to the backend automatically on launch; on-device providers are excluded.",
                provider: providerBinding,
                model: modelBinding,
                providers: ModelProviderManager.forecastEligible
            )
            HStack(spacing: 8) {
                Button("Apply to backend now") {
                    Task {
                        await env.modelProviders.pushForecastProvider(
                            client: MiroFishClient(host: env.forecastConfig.host),
                            config: env.configuration
                        )
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(env.modelProviders.forecastPushState == .pushing)
                switch env.modelProviders.forecastPushState {
                case .idle:
                    EmptyView()
                case .pushing:
                    ProgressView().controlSize(.mini)
                case .ok(let message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                        .lineLimit(2)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
        }
    }

    private func roleGroup(title: String,
                           subtitle: String,
                           provider: Binding<ProviderRegistry.ProviderID>,
                           model: Binding<String?>,
                           providers: [ProviderRegistry.ProviderID] = ProviderRegistry.ProviderID.allCases) -> some View {
        SettingsGroup(title, footer: subtitle) {
            SettingsRow("Provider", icon: "cpu") {
                Picker("", selection: provider) {
                    ForEach(providers, id: \.self) { p in
                        HStack(spacing: 6) {
                            ProviderIcon(provider: p, size: 14)
                            Text(p.displayName)
                        }
                        .tag(p)
                    }
                }
                .labelsHidden()
                .onChange(of: provider.wrappedValue) { _, _ in
                    model.wrappedValue = nil
                }
            }
            SettingsRow("Model", icon: "cube") {
                modelField(provider: provider.wrappedValue, value: model)
            }
            // Cloud, key-based providers get an inline "test key + fetch models"
            // affordance. Local/custom providers (ollama, lmstudio, custom) use
            // their dedicated host cards below.
            if cloudDiscoverable(provider.wrappedValue) {
                SettingsRow("Models", icon: "arrow.triangle.2.circlepath") {
                    HStack(spacing: 8) {
                        Button("Test key & fetch") {
                            Task { await discoverModels(for: provider.wrappedValue) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        DiscoveryStatusLabel(state: discoveryStates[provider.wrappedValue] ?? .idle,
                                             count: discovered[provider.wrappedValue]?.count ?? 0)
                    }
                }
            }
        }
    }

    /// Cloud providers that authenticate with a key and expose a model list we
    /// fetch inline (everything except the local/custom-host ones, which have
    /// their own cards).
    private func cloudDiscoverable(_ provider: ProviderRegistry.ProviderID) -> Bool {
        switch provider {
        case .anthropic, .openai, .gemini, .deepseek, .minimax, .kimi, .qwen:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private func modelField(provider: ProviderRegistry.ProviderID,
                            value: Binding<String?>) -> some View {
        let live = liveModels(for: provider)
        if provider == .ollama && live.isEmpty {
            HStack(spacing: 6) {
                TextField("qwen3:8b",
                          text: Binding(get: { value.wrappedValue ?? "" },
                                       set: { value.wrappedValue = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Button {
                    Task { await fetchOllamaModels() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh from /api/tags")
                .accessibilityLabel("Refresh Ollama models")
            }
        } else if provider.usesFreeformModel && provider != .ollama {
            freeFormModelField(provider: provider, value: value)
        } else {
            Picker("", selection: Binding(
                get: { value.wrappedValue ?? live.first ?? provider.defaultModel },
                set: { value.wrappedValue = $0 }
            )) {
                ForEach(live, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
        }
    }

    /// Editable model id with a suggestion/discovery menu — used by DeepSeek,
    /// MiniMax, Kimi, LM Studio, and custom endpoints, whose model lists either
    /// churn frequently or are server-defined.
    @ViewBuilder
    private func freeFormModelField(provider: ProviderRegistry.ProviderID,
                                    value: Binding<String?>) -> some View {
        let suggestions = modelSuggestions(for: provider)
        HStack(spacing: 6) {
            TextField(provider.defaultModel,
                      text: Binding(get: { value.wrappedValue ?? "" },
                                   set: { value.wrappedValue = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Menu {
                if suggestions.isEmpty {
                    Text("No suggestions yet")
                } else {
                    ForEach(suggestions, id: \.self) { m in
                        Button(m) { value.wrappedValue = m }
                    }
                }
                if provider.supportsModelDiscovery {
                    Divider()
                    Button("Refresh from /v1/models") {
                        Task { await discoverModels(for: provider) }
                    }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(provider.supportsModelDiscovery
                  ? "Pick a suggestion or refresh from the server"
                  : "Pick a suggested model")
        }
    }

    private func modelSuggestions(for provider: ProviderRegistry.ProviderID) -> [String] {
        var all = provider.availableModels
        if let live = discovered[provider] {
            for m in live where !all.contains(m) { all.append(m) }
        }
        return all
    }

    /// Test the provider's API key and pull its live model list. Works for every
    /// discoverable provider via `ModelDiscovery`; a success proves the key
    /// authenticates and refreshes the model suggestions.
    @MainActor
    private func discoverModels(for provider: ProviderRegistry.ProviderID) async {
        discoveryStates[provider] = .loading
        do {
            let models = try await ModelDiscovery.fetchModels(provider: provider,
                                                              config: env.configuration)
            discovered[provider] = models
            // Persist so the live catalogue survives sheet close/open and tab
            // switches (otherwise the @State is discarded and re-discovery is forced).
            DiscoveredModelsStore.save(models, for: provider)
            discoveryStates[provider] = .ok
            commitDiscoveredDefault(provider: provider, models: models)
        } catch {
            discoveryStates[provider] = .error(error.localizedDescription)
        }
    }

    /// If a role uses `provider` but has no model selected yet, adopt the first
    /// discovered model so the engine runs what the UI just listed.
    @MainActor
    private func commitDiscoveredDefault(provider: ProviderRegistry.ProviderID, models: [String]) {
        guard let first = models.first else { return }
        if env.configuration.orchestratorProvider == provider,
           (env.configuration.orchestratorModel ?? "").isEmpty {
            env.configuration.orchestratorModel = first
        }
        if env.configuration.workerProvider == provider,
           (env.configuration.workerModel ?? "").isEmpty {
            env.configuration.workerModel = first
        }
        if env.configuration.synthesisProvider == provider,
           (env.configuration.synthesisModel ?? "").isEmpty {
            env.configuration.synthesisModel = first
        }
    }

    private var ollamaCard: some View {
        SettingsGroup("Ollama discovery") {
            SettingsRow("Status", icon: "wave.3.right") {
                ollamaStatusLabel
            }
            SettingsRow("Host", icon: "network") {
                Text(env.configuration.ollamaHost.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Spacer()
                Button("Refresh") { Task { await fetchOllamaModels() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(12)
            }
        }
    }

    @ViewBuilder
    private var ollamaStatusLabel: some View {
        switch ollamaState {
        case .idle:
            Text("Not checked").font(.caption).foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Fetching…").font(.caption).foregroundStyle(.secondary)
            }
        case .ok:
            Label("\(ollamaModels.count) model\(ollamaModels.count == 1 ? "" : "s")",
                  systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .error(let msg):
            Label("Offline", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .help(msg)
        }
    }

    private func fetchOllamaModels() async {
        ollamaState = .loading
        do {
            ollamaModels = try await OllamaClient.listModels(host: env.configuration.ollamaHost)
            ollamaState = .ok
            commitOllamaDefaults()
        } catch {
            ollamaModels = []
            ollamaState = .error(error.localizedDescription)
        }
    }

    /// The Picker's synthetic Binding shows `live.first` as the default but
    /// doesn't commit it to `env.configuration` until the user manually
    /// selects something. That left workerModel == nil → makeClient falls
    /// back to the hardcoded "qwen3:8b" which the user often doesn't have.
    /// After /api/tags loads, write the first live model into any nil Ollama
    /// role so the engine sees what the UI shows.
    @MainActor
    private func commitOllamaDefaults() {
        guard let first = ollamaModels.first else { return }
        if env.configuration.orchestratorProvider == .ollama,
           (env.configuration.orchestratorModel ?? "").isEmpty {
            env.configuration.orchestratorModel = first
        }
        if env.configuration.workerProvider == .ollama,
           (env.configuration.workerModel ?? "").isEmpty {
            env.configuration.workerModel = first
        }
        if env.configuration.synthesisProvider == .ollama,
           (env.configuration.synthesisModel ?? "").isEmpty {
            env.configuration.synthesisModel = first
        }
    }

    private var usesOllama: Bool { uses(.ollama) }

    /// True when any of the three roles is assigned to `provider`.
    private func uses(_ provider: ProviderRegistry.ProviderID) -> Bool {
        env.configuration.orchestratorProvider == provider
            || env.configuration.workerProvider == provider
            || env.configuration.synthesisProvider == provider
    }

    private func liveModels(for provider: ProviderRegistry.ProviderID) -> [String] {
        if provider == .ollama { return ollamaModels }
        // Prefer the freshly-fetched catalogue when present; otherwise fall back
        // to the curated static list. Merge so a user's current pick never
        // vanishes from the picker.
        var base = provider.availableModels
        if let live = discovered[provider], !live.isEmpty {
            base = live + base.filter { !live.contains($0) }
        }
        return base
    }

    // MARK: - LM Studio

    private var lmStudioCard: some View {
        HostEndpointCard(
            title: "LM Studio",
            footer: "Start LM Studio's local server (Developer tab → Start Server) and load a model.",
            hostRowLabel: "Server URL",
            hostRowIcon: "network",
            placeholder: "http://localhost:1234",
            fieldMaxWidth: 240,
            host: $lmStudioHostString,
            status: discoveryStates[.lmstudio] ?? .idle,
            modelCount: discovered[.lmstudio]?.count ?? 0,
            onApply: { commitLMStudioHost() },
            onTest: {
                commitLMStudioHost()
                Task { await discoverModels(for: .lmstudio) }
            }
        )
    }

    // MARK: - Custom endpoint

    private var customCard: some View {
        HostEndpointCard(
            title: "Custom endpoint",
            footer: "Any OpenAI-compatible server. Paste the base URL (…/v1 optional). Set its API key under API keys → Custom Endpoint.",
            hostRowLabel: "Base URL",
            hostRowIcon: "link",
            placeholder: "https://api.example.com/v1",
            fieldMaxWidth: 280,
            host: $customHostString,
            status: discoveryStates[.custom] ?? .idle,
            modelCount: discovered[.custom]?.count ?? 0,
            onApply: { commitCustomHost() },
            onTest: {
                commitCustomHost()
                Task { await discoverModels(for: .custom) }
            }
        )
    }

    private func commitLMStudioHost() {
        // Require a real http/https scheme and a non-empty host — mirror the
        // KnowledgeTab / Qwen validation so a typo like "localhost:1234" (no
        // scheme) can't be silently accepted as a garbage URL. On rejection the
        // discovery status surfaces an actionable "Invalid host" message rather
        // than a later opaque network failure. (host-validation-allows-malformed-urls)
        let trimmed = lmStudioHostString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            discoveryStates[.lmstudio] = .error("Invalid host — use http://host:port")
            return
        }
        env.configuration.lmStudioHost = url
    }

    private func commitCustomHost() {
        let trimmed = customHostString.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            env.configuration.customEndpointBaseURL = nil
            return
        }
        // Same scheme/host requirement as LM Studio, plus a cleartext guard: the
        // custom endpoint carries a real Bearer API key, so refuse plain http://
        // to a non-loopback host where the key would travel unencrypted. http is
        // only allowed for loopback/private hosts (local LM Studio / Ollama-style
        // gateways), which URLSafety.blockReason flags as non-fetchable.
        // (host-validation-allows-malformed-urls, sec-custom-endpoint-cleartext-5)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            discoveryStates[.custom] = .error("Invalid host — use https://host/v1")
            return
        }
        if scheme == "http", URLSafety.blockReason(for: url) == nil {
            // blockReason == nil means the host is a routable public address, so
            // cleartext http there would leak the Bearer key. Require https.
            discoveryStates[.custom] = .error("Use https:// — an API key over http to a public host is sent in cleartext")
            return
        }
        env.configuration.customEndpointBaseURL = url
    }

    // MARK: - Qwen (Alibaba Cloud Model Studio)

    private var qwenCard: some View {
        HostEndpointCard(
            title: "Qwen endpoint",
            footer: "Alibaba Cloud Model Studio (MaaS), OpenAI-compatible. Paste your dedicated host (…/v1 optional). Set the key under API keys → Qwen.",
            hostRowLabel: "Base URL",
            hostRowIcon: "link",
            placeholder: "https://….maas.aliyuncs.com",
            fieldMaxWidth: 320,
            host: $qwenHostString,
            status: discoveryStates[.qwen] ?? .idle,
            modelCount: discovered[.qwen]?.count ?? 0,
            onApply: { commitQwenHost() },
            onTest: {
                commitQwenHost()
                Task { await discoverModels(for: .qwen) }
            }
        )
    }

    private func commitQwenHost() {
        let trimmed = qwenHostString.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", url.host != nil {
            env.configuration.qwenBaseURL = url
        }
    }
}

// MARK: - Providers — extracted host-card components

/// One OpenAI-compatible host endpoint (LM Studio / custom server / Qwen): a
/// base-URL field, a discovery status line, and Apply / Test buttons. The owning
/// `ProvidersTab` keeps the host string as `@State` and the commit + discovery
/// logic; this view threads that state through and forwards the two button
/// actions, so behaviour is identical to the inline cards it replaces.
private struct HostEndpointCard: View {
    let title: String
    let footer: String
    let hostRowLabel: String
    let hostRowIcon: String
    let placeholder: String
    let fieldMaxWidth: CGFloat
    @Binding var host: String
    let status: OllamaFetchState
    let modelCount: Int
    let onApply: () -> Void
    let onTest: () -> Void

    var body: some View {
        SettingsGroup(title, footer: footer) {
            SettingsRow(hostRowLabel, icon: hostRowIcon) {
                TextField(placeholder, text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: fieldMaxWidth)
                    .onSubmit(onApply)
            }
            SettingsRow("Status", icon: "wave.3.right") {
                DiscoveryStatusLabel(state: status, count: modelCount)
            }
            HStack {
                Spacer()
                Button("Apply", action: onApply)
                    .buttonStyle(.bordered).controlSize(.small)
                Button("Test & list models", action: onTest)
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(12)
        }
    }
}

/// Renders a provider's discovery / key-test state as a compact status line
/// (idle / connecting / N models / failed). Pure value-driven view extracted
/// from `ProvidersTab.discoveryStatusLabel(_:count:)`.
private struct DiscoveryStatusLabel: View {
    let state: OllamaFetchState
    let count: Int

    var body: some View {
        switch state {
        case .idle:
            Text("Not checked").font(.caption).foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }
        case .ok:
            Label("\(count) model\(count == 1 ? "" : "s")", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .error(let msg):
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .help(msg)
        }
    }
}

// MARK: - API Keys

private struct APIKeysTab: View {
    @Environment(AppEnvironment.self) private var env
    @State private var keys: [KeyAccount: String] = [:]
    @State private var saved: KeyAccount?
    @State private var testStates: [KeyAccount: TestState] = [:]

    enum TestState: Equatable { case idle, testing, ok(Int), fail(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(KeyAccount.allCases, id: \.rawValue) { account in
                SettingsGroup(account.humanLabel) {
                    VStack(spacing: 0) {
                        SettingsRow("Key", icon: "key") {
                            SecureField("Paste API key…",
                                       text: Binding(get: { keys[account] ?? "" },
                                                    set: { keys[account] = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 320)
                        }
                        HStack(spacing: 10) {
                            Link(destination: account.helpURL) {
                                Label("Get a key", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                            testResultLabel(for: account)
                            Spacer()
                            if saved == account {
                                Label("Saved", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                            // Only LLM-provider keys can be validated against a
                            // model endpoint; search keys (Tavily/Exa/Brave) have
                            // no such check.
                            if Self.provider(for: account) != nil {
                                Button("Test") { test(account) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled((keys[account] ?? "").isEmpty || testStates[account] == .testing)
                            }
                            Button("Save") {
                                let value = keys[account] ?? ""
                                Task {
                                    if value.isEmpty {
                                        await KeychainStore.shared.delete(account)
                                    } else {
                                        await KeychainStore.shared.set(value, for: account)
                                    }
                                    saved = account
                                    try? await Task.sleep(for: .seconds(1))
                                    saved = nil
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(12)
                    }
                }
            }
        }
        .task {
            for account in KeyAccount.allCases {
                keys[account] = await KeychainStore.shared.get(account) ?? ""
            }
        }
    }

    @ViewBuilder
    private func testResultLabel(for account: KeyAccount) -> some View {
        switch testStates[account] ?? .idle {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Testing…").font(.caption).foregroundStyle(.secondary)
            }
        case .ok(let n):
            Label("Valid · \(n) models", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .fail(let msg):
            Label("Invalid", systemImage: "xmark.octagon.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .labelStyle(.titleAndIcon)
                .help(msg)
        }
    }

    /// Validate the typed key: temporarily persist it, hit the provider's model
    /// endpoint, then keep it only on success. `ModelDiscovery` reads the key from
    /// the Keychain, so we must write the candidate before testing — but pressing
    /// Test on a mistyped key must not clobber a previously-working key. We snapshot
    /// the prior Keychain value and restore it if validation fails, so the only way
    /// a bad key becomes the persisted one is via the explicit Save button.
    /// (apikey-test-saves-invalid-key)
    private func test(_ account: KeyAccount) {
        guard let provider = Self.provider(for: account) else { return }
        let value = keys[account] ?? ""
        testStates[account] = .testing
        Task {
            let previous = await KeychainStore.shared.get(account)
            await KeychainStore.shared.set(value, for: account)
            do {
                let models = try await ModelDiscovery.fetchModels(provider: provider,
                                                                  config: env.configuration)
                testStates[account] = .ok(models.count)
            } catch {
                // Roll back to whatever was there before so a failed test never
                // leaves a broken key persisted for the next research/forecast run.
                if let previous {
                    await KeychainStore.shared.set(previous, for: account)
                } else {
                    await KeychainStore.shared.delete(account)
                }
                testStates[account] = .fail(error.localizedDescription)
            }
        }
    }

    /// Map a key account to the LLM provider it authenticates (nil for search keys).
    static func provider(for account: KeyAccount) -> ProviderRegistry.ProviderID? {
        switch account {
        case .anthropic: .anthropic
        case .openAI:    .openai
        case .gemini:    .gemini
        case .deepseek:  .deepseek
        case .minimax:   .minimax
        case .moonshot:  .kimi
        case .qwen:      .qwen
        case .custom:    .custom
        case .tavily, .exa, .brave: nil
        }
    }
}

// MARK: - Budget

private struct BudgetTab: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup("Preset",
                         footer: "Quickly switch between cost/quality trade-offs.") {
                HStack(spacing: 8) {
                    presetButton("Fast", isOn: env.configuration.budget == .fast) {
                        env.configuration.budget = .fast
                    }
                    presetButton("Standard", isOn: env.configuration.budget == .standard) {
                        env.configuration.budget = .standard
                    }
                    presetButton("Thorough", isOn: env.configuration.budget == .thorough) {
                        env.configuration.budget = .thorough
                    }
                    // Non-interactive indicator: highlights when the caps have been
                    // hand-tuned away from every preset, so a manual nudge no longer
                    // looks like "nothing is selected". (budget-preset-desync-no-custom-state)
                    if isCustomBudget {
                        customIndicator("Custom")
                    }
                }
                .padding(12)
            }
            SettingsGroup("Caps") {
                SettingsRow("Max tokens", icon: "circle.hexagongrid") {
                    Stepper(value: $env.configuration.budget.maxTokens,
                            in: 10_000...1_000_000, step: 10_000) {
                        Text(env.configuration.budget.maxTokens.formatted())
                            .monospacedDigit()
                            .frame(minWidth: 80, alignment: .trailing)
                    }
                }
                SettingsRow("Max workers", icon: "person.3") {
                    Stepper(value: $env.configuration.budget.maxWorkers, in: 1...8) {
                        Text("\(env.configuration.budget.maxWorkers)")
                            .monospacedDigit()
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                }
                SettingsRow("Sources per worker", icon: "doc.text") {
                    Stepper(value: $env.configuration.budget.maxSourcesPerWorker, in: 1...20) {
                        Text("\(env.configuration.budget.maxSourcesPerWorker)")
                            .monospacedDigit()
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                }
                SettingsRow("Tool calls per worker", icon: "wrench.and.screwdriver") {
                    Stepper(value: $env.configuration.budget.maxToolCallsPerWorker, in: 1...60) {
                        Text("\(env.configuration.budget.maxToolCallsPerWorker)")
                            .monospacedDigit()
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                }
                // The wall-clock cap actually aborts runs (BudgetMeter.checkWallClock),
                // and the previous fixed caps killed local-Ollama synthesis mid-run.
                // Expose it (in minutes) so users can extend it. (budget-preset-desync-no-custom-state)
                SettingsRow("Wall-clock limit", icon: "clock") {
                    Stepper(value: wallClockMinutes, in: 1...60) {
                        Text("\(wallClockMinutes.wrappedValue) min")
                            .monospacedDigit()
                            .frame(minWidth: 50, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// True when the caps have been hand-tuned away from every built-in preset.
    private var isCustomBudget: Bool {
        let b = env.configuration.budget
        return b != .fast && b != .standard && b != .thorough
    }

    /// Bridges the `Duration` wall-clock cap to an Int-minutes Stepper, rounding
    /// to whole minutes for display (sub-minute precision isn't useful here).
    private var wallClockMinutes: Binding<Int> {
        Binding(
            get: { max(1, Int((env.configuration.budget.maxWallClock.components.seconds + 30) / 60)) },
            set: { env.configuration.budget.maxWallClock = .seconds($0 * 60) }
        )
    }

    /// A read-only "Custom" capsule styled like a selected preset.
    private func customIndicator(_ label: String) -> some View {
        Text(label)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.accentColor, in: Capsule())
            .foregroundStyle(.white)
            .help("Caps differ from every preset. Pick a preset to reset.")
    }

    private func presetButton(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isOn ? Color.accentColor : Color.primary.opacity(0.06),
                           in: Capsule())
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Iteration

private struct IterationTab: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup("Preset") {
                HStack(spacing: 8) {
                    presetButton("Fast", isOn: env.configuration.iteration == .fast) {
                        env.configuration.iteration = .fast
                    }
                    presetButton("Standard", isOn: env.configuration.iteration == .standard) {
                        env.configuration.iteration = .standard
                    }
                    presetButton("Thorough", isOn: env.configuration.iteration == .thorough) {
                        env.configuration.iteration = .thorough
                    }
                    // Mirror the budget tab: a manual round/reflection tweak no
                    // longer reads as "nothing selected". (budget-preset-desync-no-custom-state)
                    if isCustomIteration {
                        customIndicator("Custom")
                    }
                }
                .padding(12)
            }
            SettingsGroup("Rounds",
                         footer: "Reflection adds an editorial critic between synthesis and an optional follow-up round.") {
                SettingsRow("Max iterations", icon: "number") {
                    Stepper(value: Binding(
                        get: { env.configuration.iteration.maxRounds },
                        set: { env.configuration.iteration = IterationController(
                            maxRounds: $0,
                            reflectAfterFirstRound: env.configuration.iteration.reflectAfterFirstRound) }
                    ), in: 1...6) {
                        Text("\(env.configuration.iteration.maxRounds)")
                            .monospacedDigit()
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                }
                SettingsRow("Reflect after first round", icon: "brain.head.profile") {
                    Toggle("", isOn: Binding(
                        get: { env.configuration.iteration.reflectAfterFirstRound },
                        set: { env.configuration.iteration = IterationController(
                            maxRounds: env.configuration.iteration.maxRounds,
                            reflectAfterFirstRound: $0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
        }
    }

    /// True when rounds/reflection have been hand-tuned away from every preset.
    private var isCustomIteration: Bool {
        let i = env.configuration.iteration
        return i != .fast && i != .standard && i != .thorough
    }

    /// A read-only "Custom" capsule styled like a selected preset.
    private func customIndicator(_ label: String) -> some View {
        Text(label)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.accentColor, in: Capsule())
            .foregroundStyle(.white)
            .help("Settings differ from every preset. Pick a preset to reset.")
    }

    private func presetButton(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isOn ? Color.accentColor : Color.primary.opacity(0.06),
                           in: Capsule())
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Knowledge base

private struct KnowledgeTab: View {
    @Environment(AppEnvironment.self) private var env
    @State private var hostString: String = ""
    @State private var health: String = "Unknown"
    @State private var sidecarBusy = false
    @State private var sidecarMessage: String = ""

    var body: some View {
        @Bindable var env = env
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup("Sidecar",
                         footer: "The Python sidecar wraps pyseekdb behind a tiny HTTP API. It launches automatically at app startup — these controls are for diagnostics and recovery.") {
                SettingsRow("Host URL", icon: "network") {
                    TextField("http://127.0.0.1:9100", text: $hostString)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                        .onSubmit { commitHost() }
                }
                SettingsRow("Status", icon: "wave.3.right") {
                    HStack(spacing: 6) {
                        if sidecarBusy { ProgressView().controlSize(.mini) }
                        Text(health)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(health.contains("✓") ? .green : .secondary)
                    }
                }
                if !sidecarMessage.isEmpty {
                    SettingsRow("Last action", icon: "info.circle") {
                        Text(sidecarMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                HStack {
                    Spacer()
                    Button("Apply") { commitHost() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Test connection") { Task { await ping() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Start / repair") { Task { await startSidecar(reinstall: false) } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(sidecarBusy)
                }
                .padding(12)
            }
            SettingsGroup("Engine") {
                SettingsRow("Include by default", icon: "books.vertical") {
                    Toggle("", isOn: $env.configuration.useKnowledgeBase)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            SettingsGroup("Dependencies",
                         footer: "First launch auto-creates a private Python virtualenv and installs pyseekdb, fastapi, uvicorn, and pydantic. Use Reinstall if the install was interrupted.") {
                HStack {
                    Button("Reinstall dependencies") { Task { await startSidecar(reinstall: true) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(sidecarBusy)
                    Spacer()
                }
                .padding(12)
            }
            DisclosureGroup("Manual setup (optional)") {
                VStack(alignment: .leading, spacing: 8) {
                    codeRow("python3 -m pip install -r sidecar/requirements.txt")
                    codeRow("python3 sidecar/seekdb_sidecar.py --port 9100")
                }
                .padding(.vertical, 8)
            }
            .font(.callout)
        }
        .task {
            hostString = env.configuration.seekdbHost.absoluteString
            await ping()
        }
    }

    private func startSidecar(reinstall: Bool) async {
        sidecarBusy = true
        sidecarMessage = reinstall ? "Reinstalling dependencies…" : "Starting sidecar…"
        let host = env.configuration.seekdbHost
        let status = reinstall
            ? await SidecarSupervisor.shared.reinstallAndStart(host: host)
            : await SidecarSupervisor.shared.ensureRunning(host: host)
        sidecarMessage = describe(status)
        await ping()
        sidecarBusy = false
    }

    private func describe(_ status: SidecarSupervisor.Status) -> String {
        switch status {
        case .running: "Sidecar running."
        case .launching: "Sidecar launching…"
        case .installingDependencies: "Installing Python dependencies…"
        case .notInstalled(let m): "Dependencies missing: \(m)"
        case .scriptMissing: "seekdb_sidecar.py not found in the app bundle."
        case .failed(let m): "Failed: \(m)"
        }
    }

    private func codeRow(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .accessibilityLabel("Copy command")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private func commitHost() {
        // Require a real scheme (http/https) so a typo like "localhost:9100"
        // can't silently point the sidecar at an unusable URL — mirror the
        // LM Studio / custom-endpoint validation.
        let trimmed = hostString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            health = "✗ Invalid host — use http://host:port"
            return
        }
        env.configuration.seekdbHost = url
    }

    private func ping() async {
        // Reflect the supervisor's lifecycle so the at-rest status isn't a
        // misleading "Unreachable" while the sidecar is starting or installing.
        let status = await SidecarSupervisor.shared.currentStatus()
        switch status {
        case .launching:
            health = "… Starting sidecar"
            return
        case .installingDependencies:
            health = "… Installing dependencies (first run)"
            return
        default:
            break
        }
        let client = SeekDBClient(host: env.configuration.seekdbHost)
        do {
            let h = try await client.health()
            let mode = h.mode.map { " \($0)" } ?? ""
            health = "✓ Online\(mode) — \(h.documents ?? 0) docs"
        } catch SeekDBClient.SeekDBError.unreachable {
            health = "✗ Unreachable"
        } catch {
            health = "✗ \(error.localizedDescription)"
        }
    }
}

// MARK: - Forecast (MiroFish backend)

private struct ForecastTab: View {
    @Environment(AppEnvironment.self) private var env
    @State private var repoPath: String = ""
    @State private var hostString: String = ""
    @State private var checking = false

    // Backend environment repair (uv venv --python 3.12 + uv sync)
    @State private var repairing = false
    @State private var repairMessage: String?
    @State private var repairFailed = false

    // Runtime LLM provider (backend /api/settings/llm)
    @State private var providerInfo: MFProviderInfo?
    @State private var selectedProvider: String = ""
    @State private var providerKey: String = ""
    @State private var providerBusy = false
    @State private var providerMessage: String?

    var body: some View {
        @Bindable var env = env
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup("Backend status",
                         footer: "The forecast backend runs DeerFlow deep-research, builds a local Graphiti knowledge graph (embedded FalkorDB, no API key), runs the OASIS multi-agent simulation, and writes the report.") {
                SettingsRow("Status", icon: "wave.3.right") {
                    HStack(spacing: 6) {
                        if checking { ProgressView().controlSize(.mini) }
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(statusText).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                    }
                }
                HStack {
                    Button("Setup assistant…") {
                        env.settingsOpen = false
                        env.workspace = .forecast   // the sheet hangs off the Forecast workspace
                        env.forecastOnboardingOpen = true
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Guided first-run setup: dependency checks, setup.sh, and backend launch.")
                    Spacer()
                    Button("Check") { Task { await check() } }
                        .buttonStyle(.bordered).controlSize(.small).disabled(checking)
                    Button("Start backend") { Task { await start() } }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(checking)
                }
                .padding(12)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Python environment", systemImage: "stethoscope")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if repairing { ProgressView().controlSize(.mini) }
                        Button(repairing ? "Repairing…" : "Repair environment") {
                            Task { await repair() }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(repairing)
                        .help("Rebuilds backend/.venv on Python 3.12 and reinstalls dependencies with uv. Use this when the backend fails with import errors. Takes a few minutes.")
                    }
                    if let repairMessage {
                        Text(repairMessage)
                            .font(.caption2)
                            .foregroundStyle(repairFailed ? Color.orange : Color.secondary)
                            .textSelection(.enabled)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
            }

            SettingsGroup("LLM provider (backend live state)",
                         footer: "The backend's current provider. Normally set automatically from Providers → Forecast (MiroFish); this panel reads the live state and lets you override it manually — e.g. for CLI providers (claude-cli, codex-cli), which use your local subscription and need no key. Switching applies to newly started forecasts.") {
                if let info = providerInfo {
                    SettingsRow("Provider", icon: "cpu") {
                        Picker("", selection: $selectedProvider) {
                            ForEach(info.providers ?? []) { p in
                                // Annotate options that require a key the backend
                                // doesn't yet have, so the user can tell a CLI/no-key
                                // provider from one that will fail without a key.
                                Text(optionLabel(p, info: info)).tag(p.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    if selectedProviderNeedsKey(info) {
                        SettingsRow("API key", icon: "key") {
                            SecureField(keyPlaceholder(info), text: $providerKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 300)
                        }
                    }
                    // Up-front eligibility warning: the picker lets you select a
                    // key-requiring provider even when no key is configured, which
                    // would only surface as an opaque failure at run time.
                    if selectedProviderMissingKey(info) {
                        Label("This provider needs an API key — enter one above before applying.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 12)
                    }
                    HStack {
                        if let providerMessage {
                            Text(providerMessage)
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        if providerBusy { ProgressView().controlSize(.mini) }
                        Button("Apply") { Task { await applyProvider() } }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(providerBusy || selectedProvider.isEmpty
                                      || selectedProviderMissingKey(info)
                                      || selectedProvider == info.current && providerKey.isEmpty)
                    }
                    .padding(12)
                } else {
                    HStack {
                        Text("Start the backend to view and switch its LLM provider.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Load") { Task { await loadProviderInfo() } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(12)
                }
            }

            SettingsGroup("Backend location",
                         footer: "The DeepResearchForecast repository folder (contains `backend/run.py` and `setup.sh`). The backend launches from its own Python ≤3.12 virtualenv (`backend/.venv`) or via `uv`.") {
                SettingsRow("Folder", icon: "folder") {
                    HStack(spacing: 6) {
                        TextField("~/Downloads/DeepResearchForecast", text: $repoPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                            .onSubmit { commitRepoPath() }
                        Button("Choose…") { chooseFolder() }
                            .controlSize(.small)
                    }
                }
                SettingsRow("Host URL", icon: "network") {
                    TextField("http://127.0.0.1:5001", text: $hostString)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .onSubmit { commitHost() }
                }
                SettingsRow("Auto-launch on demand", icon: "bolt.fill") {
                    Toggle("", isOn: $env.forecastConfig.autoLaunchBackend)
                        .toggleStyle(.switch).labelsHidden()
                }
                SettingsRow("Default research depth", icon: "slider.horizontal.3") {
                    Picker("", selection: $env.forecastConfig.defaultDepth) {
                        Text("Quick").tag("quick")
                        Text("Standard").tag("standard")
                        Text("Deep").tag("deep")
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            SettingsGroup("Knowledge graph",
                         footer: "The knowledge graph runs locally via Graphiti + an embedded FalkorDB — no account, no Docker, no API key. The first forecast downloads a ~470MB multilingual embedding model once, then caches it.") {
                HStack {
                    Label("Provider settings sync to the backend's .env on launch", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync now") { Task { await env.syncMiroFishEnv() } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(12)
            }
        }
        .onChange(of: env.forecastConfig) { _, _ in env.saveForecastConfiguration() }
        .onAppear {
            repoPath = env.forecastConfig.repoRootPath
            hostString = env.forecastConfig.hostString
        }
        .task { await check() }
    }

    private var statusColor: Color {
        switch env.forecastBackendStatus {
        case .running: .green
        case .launching: .blue
        case .stopped: .secondary
        case .backendMissing, .interpreterMissing: .orange
        case .failed: .red
        }
    }

    private var statusText: String {
        switch env.forecastBackendStatus {
        case .running: "Running — connected at \(env.forecastConfig.hostString)"
        case .launching: "Launching…"
        case .stopped: "Stopped"
        case .backendMissing(let m), .interpreterMissing(let m), .failed(let m): m
        }
    }

    private func check() async {
        checking = true
        _ = await MiroFishSupervisor.shared.checkHealth(host: env.forecastConfig.host)
        env.forecastBackendStatus = await MiroFishSupervisor.shared.currentStatus()
        checking = false
        if case .running = env.forecastBackendStatus, providerInfo == nil {
            await loadProviderInfo()
        }
    }

    private func start() async {
        checking = true
        commitRepoPath(); commitHost()
        env.forecastBackendStatus = await MiroFishSupervisor.shared.ensureRunning(
            host: env.forecastConfig.host, repoRoot: env.forecastConfig.repoRoot)
        checking = false
        if case .running = env.forecastBackendStatus { await loadProviderInfo() }
    }

    private func repair() async {
        commitRepoPath()
        repairing = true
        repairFailed = false
        repairMessage = "Rebuilding backend/.venv on Python 3.12 — this can take a few minutes…"
        do {
            _ = try await MiroFishSupervisor.shared.repairEnvironment(repoRoot: env.forecastConfig.repoRoot)
            repairMessage = "Environment rebuilt. Starting the backend…"
            env.forecastBackendStatus = await MiroFishSupervisor.shared.ensureRunning(
                host: env.forecastConfig.host, repoRoot: env.forecastConfig.repoRoot)
            if case .running = env.forecastBackendStatus {
                repairMessage = "Environment rebuilt — backend is running."
                await loadProviderInfo()
            } else {
                repairFailed = true
                repairMessage = AppEnvironment.backendMessage(env.forecastBackendStatus)
            }
        } catch {
            repairFailed = true
            repairMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        repairing = false
    }

    // MARK: LLM provider

    private func loadProviderInfo() async {
        let client = MiroFishClient(host: env.forecastConfig.host)
        guard let info = try? await client.providerInfo() else { return }
        providerInfo = info
        if selectedProvider.isEmpty { selectedProvider = info.current ?? "" }
    }

    private func selectedProviderNeedsKey(_ info: MFProviderInfo) -> Bool {
        (info.providers ?? []).first(where: { $0.id == selectedProvider })?.needs_key == true
    }

    /// A key-requiring provider has no usable key when it isn't the currently
    /// configured one (whose key the backend already holds) and the entry field
    /// is empty. The backend only reports `has_api_key` for `current`, so for any
    /// other selection we require the user to supply a key before applying.
    private func selectedProviderMissingKey(_ info: MFProviderInfo) -> Bool {
        guard selectedProviderNeedsKey(info) else { return false }
        let keyEntered = !providerKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isConfiguredCurrent = selectedProvider == info.current && info.has_api_key == true
        return !keyEntered && !isConfiguredCurrent
    }

    /// Picker label that flags a key-requiring provider the backend can't yet use,
    /// so the gap is visible before selection rather than only at run time.
    private func optionLabel(_ p: MFProvider, info: MFProviderInfo) -> String {
        let base = p.label ?? p.id
        guard p.needs_key == true else { return base }
        let configured = p.id == info.current && info.has_api_key == true
        return configured ? base : "\(base) — needs key"
    }

    private func keyPlaceholder(_ info: MFProviderInfo) -> String {
        if selectedProvider == info.current, info.has_api_key == true {
            return "configured — leave blank to keep"
        }
        return "API key"
    }

    private func applyProvider() async {
        guard !selectedProvider.isEmpty else { return }
        providerBusy = true
        providerMessage = nil
        let client = MiroFishClient(host: env.forecastConfig.host)
        do {
            let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let info = try await client.setProvider(selectedProvider,
                                                    apiKey: key.isEmpty ? nil : key)
            providerInfo = info
            providerKey = ""
            providerMessage = "Switched to \(info.current ?? selectedProvider) (research model: \(info.deerflow_model ?? "—")). Applies to new forecasts."
        } catch {
            providerMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        providerBusy = false
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            repoPath = url.path
            commitRepoPath()
        }
    }

    private func commitRepoPath() {
        let trimmed = repoPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        env.forecastConfig.repoRootPath = (trimmed as NSString).expandingTildeInPath
        env.saveForecastConfiguration()
    }

    private func commitHost() {
        let trimmed = hostString.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", url.host != nil {
            env.forecastConfig.hostString = trimmed
            env.saveForecastConfiguration()
        }
    }
}

// MARK: - Instructions

private struct InstructionsTab: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        @Bindable var env = env
        SettingsGroup("System addendum",
                     footer: "Appended to planner, worker, and synthesizer prompts.") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $env.configuration.systemPromptAddendum)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 240)
                    .padding(8)
                    .background(Color.primary.opacity(0.04),
                               in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button("Clear") { env.configuration.systemPromptAddendum = "" }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    Spacer()
                    Text("\(env.configuration.systemPromptAddendum.count) characters")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Swift Deep Research")
                        .font(.title2.weight(.bold))
                    Text("v2.0 · macOS 26 Tahoe · Swift 6.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("An open-source, on-device-first deep research agent. Decomposes questions into parallel sub-tasks, dispatches tool-using workers, and synthesizes cited answers.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsGroup("Architecture") {
                VStack(alignment: .leading, spacing: 8) {
                    aboutRow("person.3.fill", "Orchestrator-worker pattern (Anthropic-inspired)", .blue)
                    aboutRow("brain.head.profile", "11 LLM providers — Claude, OpenAI, Gemini, DeepSeek, MiniMax, Kimi, LM Studio, Ollama, MLX, custom", .purple)
                    aboutRow("magnifyingglass", "Tavily / Exa / Brave / DuckDuckGo fallback chain", .orange)
                    aboutRow("doc.text", "Static HTML + JS-rendered SPA reader", .teal)
                    aboutRow("books.vertical.fill", "pyseekdb vector knowledge base", .indigo)
                    aboutRow("quote.bubble.fill", "Inline numbered citations with exact-quote grounding", .pink)
                    aboutRow("key.fill", "Keychain-backed API keys, never on disk", .yellow)
                }
                .padding(12)
            }
        }
    }

    private func aboutRow(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(color)
                .frame(width: 22)
            Text(text)
                .font(.callout)
        }
    }
}
