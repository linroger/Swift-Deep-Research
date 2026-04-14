import SwiftUI

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()
    
    // MARK: - LLM Providers
    @Published var localLLMProvider: LocalLLMProvider
    @Published var geminiProvider: GeminiProvider
    @Published var ollamaProvider: OllamaProvider
    
    // MARK: - Current Provider
    @Published var currentProviderType: LLMProviderType {
        didSet {
            AppSettings.shared.currentProvider = currentProviderType
            objectWillChange.send()
        }
    }
    
    // MARK: - App State
    @Published var isProcessing: Bool = false
    @Published var showOnboarding: Bool = false
    
    // MARK: - Managers
    let memoryManager = MemoryManager.shared
    let promptManager = CustomPromptManager.shared
    let conversationManager = ConversationManager.shared
    
    private init() {
        let settings = AppSettings.shared
        
        // Initialize current provider type
        self.currentProviderType = settings.currentProvider
        
        // Initialize Gemini Provider
        let geminiConfig = GeminiConfig(
            apiKey: settings.geminiApiKey,
            modelName: settings.geminiModel.rawValue
        )
        self.geminiProvider = GeminiProvider(config: geminiConfig)
        
        // Initialize Ollama Provider
        let ollamaConfig = OllamaConfig(
            host: settings.ollamaHost,
            selectedModel: settings.ollamaModel
        )
        self.ollamaProvider = OllamaProvider(config: ollamaConfig)
        
        // Initialize Local MLX Provider
        self.localLLMProvider = LocalLLMProvider()
        
        // Check Ollama connection on startup
        Task {
            await ollamaProvider.refreshModels()
        }
    }
    
    // MARK: - Active Provider
    
    /// Returns the currently active LLM provider based on user selection
    var activeLLMProvider: LLMProviderProtocol {
        switch currentProviderType {
        case .gemini:
            return geminiProvider
        case .ollama:
            return ollamaProvider
        case .localMLX:
            return localLLMProvider
        }
    }
    
    /// Get the display name of the current provider
    var currentProviderName: String {
        switch currentProviderType {
        case .gemini:
            return "Gemini \(AppSettings.shared.geminiModel.displayName)"
        case .ollama:
            return "Ollama: \(ollamaProvider.selectedModel)"
        case .localMLX:
            return "MLX Local"
        }
    }
    
    // MARK: - Provider Management
    
    func setCurrentProvider(_ type: LLMProviderType) {
        currentProviderType = type
    }
    
    /// Update Gemini configuration
    func saveGeminiConfig(apiKey: String, model: GeminiModel) {
        AppSettings.shared.geminiApiKey = apiKey
        AppSettings.shared.geminiModel = model
        
        let config = GeminiConfig(apiKey: apiKey, modelName: model.rawValue)
        geminiProvider = GeminiProvider(config: config)
    }
    
    /// Update Ollama configuration
    func saveOllamaConfig(host: String, model: String) {
        AppSettings.shared.ollamaHost = host
        AppSettings.shared.ollamaModel = model
        
        ollamaProvider.updateHost(host)
        ollamaProvider.selectModel(model)
    }
    
    // MARK: - System Prompt
    
    /// Get the current system prompt with memory context
    func getSystemPrompt() -> String {
        var prompt = promptManager.selectedPrompt?.content ?? ""
        
        // Inject memory context if enabled
        if AppSettings.shared.enableMemory {
            prompt += memoryManager.formatForPrompt()
        }
        
        return prompt
    }
}
