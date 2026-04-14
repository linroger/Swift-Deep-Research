import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var appState: AppState
    @ObservedObject var settings = AppSettings.shared
    
    @State private var selectedTab = 0
    
    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                ProvidersSettingsTab(appState: appState)
                    .tabItem {
                        Label("Providers", systemImage: "cpu")
                    }
                    .tag(0)
                
                ResearchSettingsTab()
                    .tabItem {
                        Label("Research", systemImage: "magnifyingglass")
                    }
                    .tag(1)
                
                MemorySettingsTab()
                    .tabItem {
                        Label("Memory", systemImage: "brain")
                    }
                    .tag(2)
                
                AppearanceSettingsTab()
                    .tabItem {
                        Label("Appearance", systemImage: "paintbrush")
                    }
                    .tag(3)
            }
            .frame(minWidth: 600, minHeight: 500)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Providers Tab

struct ProvidersSettingsTab: View {
    @ObservedObject var appState: AppState
    @ObservedObject var settings = AppSettings.shared
    
    var body: some View {
        Form {
            Section("Active Provider") {
                Picker("Provider", selection: $settings.currentProvider) {
                    ForEach(LLMProviderType.allCases) { provider in
                        HStack {
                            Image(systemName: provider.icon)
                            Text(provider.displayName)
                        }
                        .tag(provider)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: settings.currentProvider) { _, newValue in
                    appState.setCurrentProvider(newValue)
                }
                
                Text(settings.currentProvider.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            switch settings.currentProvider {
            case .gemini:
                GeminiSettingsSection(appState: appState)
            case .ollama:
                OllamaSettingsSection(appState: appState)
            case .localMLX:
                LocalMLXSettingsSection(appState: appState)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Gemini Settings

struct GeminiSettingsSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var settings = AppSettings.shared
    @State private var apiKey: String = ""
    
    var body: some View {
        Section("Gemini AI Configuration") {
            SecureField("API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .onAppear { apiKey = settings.geminiApiKey }
                .onChange(of: apiKey) { _, newValue in
                    settings.geminiApiKey = newValue
                    appState.saveGeminiConfig(apiKey: newValue, model: settings.geminiModel)
                }
            
            Picker("Model", selection: $settings.geminiModel) {
                ForEach(GeminiModel.allCases, id: \.self) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .onChange(of: settings.geminiModel) { _, newValue in
                appState.saveGeminiConfig(apiKey: settings.geminiApiKey, model: newValue)
            }
            
            HStack {
                Button("Get API Key") {
                    if let url = URL(string: "https://aistudio.google.com/app/apikey") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                
                Spacer()
                
                if !settings.geminiApiKey.isEmpty {
                    Label("Configured", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Label("Not configured", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
            }
        }
    }
}

// MARK: - Ollama Settings

struct OllamaSettingsSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var ollamaProvider: OllamaProvider
    @State private var host: String = ""
    @State private var isRefreshing = false
    
    init(appState: AppState) {
        self.appState = appState
        self.ollamaProvider = appState.ollamaProvider
    }
    
    var body: some View {
        Section("Ollama Configuration") {
            HStack {
                TextField("Host URL", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { host = AppSettings.shared.ollamaHost }
                
                Button("Connect") {
                    appState.saveOllamaConfig(host: host, model: ollamaProvider.selectedModel)
                    Task {
                        isRefreshing = true
                        await ollamaProvider.refreshModels()
                        isRefreshing = false
                    }
                }
            }
            
            // Connection status
            HStack {
                if isRefreshing {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if ollamaProvider.isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Label("Not connected", systemImage: "xmark.circle.fill")
                        .foregroundColor(.red)
                }
                
                Spacer()
                
                Button {
                    Task {
                        isRefreshing = true
                        await ollamaProvider.refreshModels()
                        isRefreshing = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isRefreshing)
            }
            
            if let error = ollamaProvider.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        
        if ollamaProvider.isConnected && !ollamaProvider.availableModels.isEmpty {
            Section("Available Models") {
                Picker("Selected Model", selection: Binding(
                    get: { ollamaProvider.selectedModel },
                    set: { ollamaProvider.selectModel($0) }
                )) {
                    ForEach(ollamaProvider.availableModels) { model in
                        HStack {
                            Text(model.name)
                            Spacer()
                            Text(model.formattedSize)
                                .foregroundColor(.secondary)
                        }
                        .tag(model.name)
                    }
                }
                
                Text("\(ollamaProvider.availableModels.count) models available")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        
        Section("Install Ollama") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ollama runs large language models locally on your Mac.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack {
                    Button("Download Ollama") {
                        if let url = URL(string: "https://ollama.com/download") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    
                    Button("Browse Models") {
                        if let url = URL(string: "https://ollama.com/library") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Local MLX Settings

struct LocalMLXSettingsSection: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        LocalLLMSettingsView(evaluator: appState.localLLMProvider)
    }
}

// MARK: - Research Settings Tab

struct ResearchSettingsTab: View {
    @ObservedObject var settings = AppSettings.shared
    
    var body: some View {
        Form {
            Section("Search Settings") {
                Stepper("Max Search Results: \(settings.maxSearchResults)", 
                        value: $settings.maxSearchResults, 
                        in: 3...20)
                
                Stepper("Max Research Iterations: \(settings.maxResearchIterations)", 
                        value: $settings.maxResearchIterations, 
                        in: 1...10)
            }
            
            Section("Response Settings") {
                Toggle("Enable Streaming", isOn: $settings.enableStreaming)
                Toggle("Show Sources", isOn: $settings.showSources)
            }
            
            Section("System Prompts") {
                NavigationLink("Manage Prompts") {
                    PromptEditorView()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Memory Settings Tab

struct MemorySettingsTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var memoryManager = MemoryManager.shared
    @State private var showClearConfirmation = false
    
    var body: some View {
        Form {
            Section("Memory Settings") {
                Toggle("Enable AI Memory", isOn: $settings.enableMemory)
                
                Text("When enabled, the AI can remember information about you and your projects to provide more personalized assistance.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("Memory Statistics") {
                HStack {
                    Text("Total Memories")
                    Spacer()
                    Text("\(memoryManager.memories.count)")
                        .foregroundColor(.secondary)
                }
                
                ForEach(MemoryCategory.allCases, id: \.self) { category in
                    HStack {
                        Image(systemName: category.icon)
                        Text(category.rawValue)
                        Spacer()
                        Text("\(memoryManager.memories(for: category).count)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Section("Memory Management") {
                NavigationLink("View & Edit Memories") {
                    MemoryListView()
                }
                
                Button("Clear All Memories", role: .destructive) {
                    showClearConfirmation = true
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert("Clear All Memories?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                memoryManager.clearAllMemories()
            }
        } message: {
            Text("This will permanently delete all stored memories. This action cannot be undone.")
        }
    }
}

// MARK: - Appearance Settings Tab

struct AppearanceSettingsTab: View {
    @ObservedObject var settings = AppSettings.shared
    
    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            
            Section("Text Size") {
                Picker("Font Size", selection: $settings.fontSize) {
                    ForEach(FontSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                
                // Preview
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("This is how text will appear in the chat.")
                        .font(.system(size: settings.fontSize.bodySize))
                    
                    Text("This is caption text for sources and timestamps.")
                        .font(.system(size: settings.fontSize.captionSize))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Section("Display Options") {
                Toggle("Show Reasoning Traces", isOn: $settings.showReasoningTraces)
                Text("Display the model's step-by-step reasoning during research")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Toggle("Show Sources", isOn: $settings.showSources)
                Text("Show source citations below AI responses")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Build")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                        .foregroundColor(.secondary)
                }
                
                Link("View on GitHub", destination: URL(string: "https://github.com")!)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct LocalLLMSettingsView: View {
    @ObservedObject var evaluator: LocalLLMProvider
    @State private var showingDeleteAlert = false
    @State private var showingErrorAlert = false
    
    var body: some View {
        Section("MLX On-Device Model") {
            VStack(alignment: .leading, spacing: 16) {
                // Model info
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        InfoRow(label: "Model", value: "Qwen2.5-7B-Instruct-1M")
                        InfoRow(label: "Quantization", value: "4-bit")
                        InfoRow(label: "Size", value: "~8GB")
                        InfoRow(label: "Optimized for", value: "Apple Silicon")
                    }
                    .padding(.vertical, 4)
                }
                
                // Status
                if !evaluator.modelInfo.isEmpty {
                    Text(evaluator.modelInfo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Actions
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        if evaluator.isDownloading {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Downloading model...")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Button("Cancel") {
                                        evaluator.cancelDownload()
                                    }
                                    .foregroundColor(.red)
                                }
                                
                                ProgressView(value: evaluator.downloadProgress) {
                                    Text("\(Int(evaluator.downloadProgress * 100))%")
                                        .font(.caption)
                                }
                            }
                        } else if evaluator.running {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Loading model...")
                                    .foregroundColor(.secondary)
                            }
                        } else if case .idle = evaluator.loadState {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Model needs to be downloaded before first use")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                
                                HStack {
                                    Button("Download Model") {
                                        evaluator.startDownload()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    
                                    if evaluator.lastError != nil {
                                        Button("Retry") {
                                            evaluator.retryDownload()
                                        }
                                        .disabled(evaluator.retryCount >= 3)
                                    }
                                }
                                
                                if let error = evaluator.lastError {
                                    Text(error)
                                        .foregroundColor(.red)
                                        .font(.caption)
                                }
                            }
                        } else {
                            HStack {
                                Label("Model ready", systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                
                                Spacer()
                                
                                Button("Delete Model", role: .destructive) {
                                    showingDeleteAlert = true
                                }
                            }
                        }
                    }
                }
                
                // Stats
                if !evaluator.stat.isEmpty {
                    Text(evaluator.stat)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .alert("Delete Model", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                do {
                    try evaluator.deleteModel()
                } catch {
                    evaluator.lastError = "Failed to delete: \(error.localizedDescription)"
                    showingErrorAlert = true
                }
            }
        } message: {
            Text("Delete the downloaded model? You'll need to download it again to use local processing.")
        }
        .alert("Error", isPresented: $showingErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            if let error = evaluator.lastError {
                Text(error)
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
    }
}
