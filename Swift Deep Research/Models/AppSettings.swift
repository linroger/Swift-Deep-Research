import Foundation

/// Available LLM provider types
enum LLMProviderType: String, CaseIterable, Identifiable, Codable {
    case gemini = "gemini"
    case ollama = "ollama"
    case localMLX = "local"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .gemini: return "Gemini AI"
        case .ollama: return "Ollama (Local)"
        case .localMLX: return "MLX (On-Device)"
        }
    }
    
    var description: String {
        switch self {
        case .gemini: return "Google's Gemini models via API"
        case .ollama: return "Local models via Ollama server"
        case .localMLX: return "On-device models using Apple MLX"
        }
    }
    
    var icon: String {
        switch self {
        case .gemini: return "cloud.fill"
        case .ollama: return "server.rack"
        case .localMLX: return "cpu.fill"
        }
    }
}

/// A singleton for app-wide settings that wraps UserDefaults access
@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    private let defaults = UserDefaults.standard
    
    // MARK: - Provider Settings
    @Published var currentProvider: LLMProviderType {
        didSet { defaults.set(currentProvider.rawValue, forKey: "current_provider") }
    }
    
    // MARK: - Gemini Settings
    @Published var geminiApiKey: String {
        didSet { defaults.set(geminiApiKey, forKey: "gemini_api_key") }
    }
    
    @Published var geminiModel: GeminiModel {
        didSet { defaults.set(geminiModel.rawValue, forKey: "gemini_model") }
    }
    
    // MARK: - Ollama Settings
    @Published var ollamaHost: String {
        didSet { defaults.set(ollamaHost, forKey: "ollama_host") }
    }
    
    @Published var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: "ollama_model") }
    }
    
    // MARK: - Research Settings
    @Published var maxSearchResults: Int {
        didSet { defaults.set(maxSearchResults, forKey: "max_search_results") }
    }
    
    @Published var maxResearchIterations: Int {
        didSet { defaults.set(maxResearchIterations, forKey: "max_research_iterations") }
    }
    
    @Published var enableMemory: Bool {
        didSet { defaults.set(enableMemory, forKey: "enable_memory") }
    }
    
    @Published var enableStreaming: Bool {
        didSet { defaults.set(enableStreaming, forKey: "enable_streaming") }
    }
    
    // MARK: - UI Settings
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "app_theme") }
    }
    
    @Published var showSources: Bool {
        didSet { defaults.set(showSources, forKey: "show_sources") }
    }
    
    @Published var fontSize: FontSize {
        didSet { defaults.set(fontSize.rawValue, forKey: "font_size") }
    }
    
    @Published var showReasoningTraces: Bool {
        didSet { defaults.set(showReasoningTraces, forKey: "show_reasoning_traces") }
    }
    
    // MARK: - Init
    private init() {
        let defaults = UserDefaults.standard
        
        // Load provider settings
        let providerStr = defaults.string(forKey: "current_provider") ?? "gemini"
        self.currentProvider = LLMProviderType(rawValue: providerStr) ?? .gemini
        
        // Load Gemini settings
        self.geminiApiKey = defaults.string(forKey: "gemini_api_key") ?? ""
        let geminiModelStr = defaults.string(forKey: "gemini_model") ?? GeminiModel.twoflash.rawValue
        self.geminiModel = GeminiModel(rawValue: geminiModelStr) ?? .twoflash
        
        // Load Ollama settings
        self.ollamaHost = defaults.string(forKey: "ollama_host") ?? OllamaConfig.defaultHost
        self.ollamaModel = defaults.string(forKey: "ollama_model") ?? OllamaConfig.defaultModel
        
        // Load research settings
        let savedMaxSearchResults = defaults.integer(forKey: "max_search_results")
        self.maxSearchResults = savedMaxSearchResults == 0 ? 10 : savedMaxSearchResults
        
        let savedMaxIterations = defaults.integer(forKey: "max_research_iterations")
        self.maxResearchIterations = savedMaxIterations == 0 ? 5 : savedMaxIterations
        
        self.enableMemory = defaults.object(forKey: "enable_memory") == nil ? true : defaults.bool(forKey: "enable_memory")
        self.enableStreaming = defaults.object(forKey: "enable_streaming") == nil ? true : defaults.bool(forKey: "enable_streaming")
        
        // Load UI settings
        let themeStr = defaults.string(forKey: "app_theme") ?? "system"
        self.theme = AppTheme(rawValue: themeStr) ?? .system
        
        self.showSources = defaults.object(forKey: "show_sources") == nil ? true : defaults.bool(forKey: "show_sources")
        
        let fontSizeStr = defaults.string(forKey: "font_size") ?? "medium"
        self.fontSize = FontSize(rawValue: fontSizeStr) ?? .medium
        
        self.showReasoningTraces = defaults.object(forKey: "show_reasoning_traces") == nil ? true : defaults.bool(forKey: "show_reasoning_traces")
    }
    
    // MARK: - Convenience
    func resetAll() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
    }
}

/// App theme options
enum AppTheme: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Font size options
enum FontSize: String, CaseIterable, Identifiable {
    case small = "small"
    case medium = "medium"
    case large = "large"
    case extraLarge = "extraLarge"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }
    
    var bodySize: CGFloat {
        switch self {
        case .small: return 12
        case .medium: return 14
        case .large: return 16
        case .extraLarge: return 18
        }
    }
    
    var captionSize: CGFloat {
        switch self {
        case .small: return 10
        case .medium: return 12
        case .large: return 13
        case .extraLarge: return 14
        }
    }
    
    var headlineSize: CGFloat {
        switch self {
        case .small: return 14
        case .medium: return 16
        case .large: return 18
        case .extraLarge: return 20
        }
    }
}
