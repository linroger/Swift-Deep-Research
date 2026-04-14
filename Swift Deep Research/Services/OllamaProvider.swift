import Foundation
import Ollama

/// Configuration for Ollama provider
struct OllamaConfig: Codable {
    var host: String
    var selectedModel: String
    
    static let defaultHost = "http://localhost:11434"
    static let defaultModel = "llama3.2"
}

/// Information about an available Ollama model
struct OllamaModelInfo: Identifiable, Codable, Hashable {
    var id: String { name }
    let name: String
    let size: Int64
    let modifiedAt: Date
    let parameterSize: String?
    let quantizationLevel: String?
    
    var formattedSize: String {
        let gb = Double(size) / (1024 * 1024 * 1024)
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        } else {
            let mb = Double(size) / (1024 * 1024)
            return String(format: "%.0f MB", mb)
        }
    }
}

/// Provider for Ollama local LLM models
@MainActor
class OllamaProvider: ObservableObject, LLMProviderProtocol {
    @Published var isProcessing = false
    @Published var isConnected = false
    @Published var availableModels: [OllamaModelInfo] = []
    @Published var selectedModel: String = OllamaConfig.defaultModel
    @Published var lastError: String?
    @Published var currentOutput: String = ""
    @Published var tokensPerSecond: Double = 0
    
    private var client: Client
    private var config: OllamaConfig
    
    init(config: OllamaConfig = OllamaConfig(host: OllamaConfig.defaultHost, 
                                              selectedModel: OllamaConfig.defaultModel)) {
        self.config = config
        self.selectedModel = config.selectedModel
        
        if let hostURL = URL(string: config.host) {
            self.client = Client(host: hostURL)
        } else {
            self.client = Client.default
        }
    }
    
    /// Refresh available models from Ollama server
    func refreshModels() async {
        do {
            let response = try await client.listModels()
            
            availableModels = response.models.map { model in
                // Parse the modifiedAt string to Date
                let dateFormatter = ISO8601DateFormatter()
                dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let modifiedDate = dateFormatter.date(from: model.modifiedAt) ?? Date()
                
                return OllamaModelInfo(
                    name: model.name,
                    size: model.size,
                    modifiedAt: modifiedDate,
                    parameterSize: model.details.parameterSize,
                    quantizationLevel: model.details.quantizationLevel
                )
            }.sorted { $0.name < $1.name }
            
            isConnected = true
            lastError = nil
            
            // If selected model not in list, select first available
            if !availableModels.isEmpty && !availableModels.contains(where: { $0.name == selectedModel }) {
                selectedModel = availableModels[0].name
            }
        } catch {
            isConnected = false
            availableModels = []
            lastError = "Failed to connect to Ollama: \(error.localizedDescription)"
        }
    }
    
    /// Check if Ollama server is running
    func checkConnection() async -> Bool {
        do {
            _ = try await client.listModels()
            isConnected = true
            lastError = nil
            return true
        } catch {
            isConnected = false
            lastError = "Ollama not running. Start it with: ollama serve"
            return false
        }
    }
    
    /// Update host URL
    func updateHost(_ newHost: String) {
        config.host = newHost
        if let hostURL = URL(string: newHost) {
            client = Client(host: hostURL)
        }
        Task {
            await refreshModels()
        }
    }
    
    /// Select a model
    func selectModel(_ modelName: String) {
        selectedModel = modelName
        config.selectedModel = modelName
    }
    
    /// Pull (download) a model from Ollama library
    func pullModel(_ modelName: String, progress: @escaping (Double) -> Void) async throws {
        // Use non-streaming pull for simplicity
        try await client.pullModel(Model.ID(stringLiteral: modelName))
        await refreshModels()
    }
    
    /// Delete a model
    func deleteModel(_ modelName: String) async throws {
        try await client.deleteModel(Model.ID(stringLiteral: modelName))
        await refreshModels()
    }
    
    /// Process text using Ollama with streaming
    func processText(systemPrompt: String?, 
                     userPrompt: String,
                     streaming: Bool = true) async throws -> String {
        if !isConnected {
            let connected = await checkConnection()
            if !connected {
                throw NSError(domain: "OllamaProvider", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Ollama is not running. Please start Ollama first."])
            }
        }
        
        isProcessing = true
        currentOutput = ""
        
        defer { 
            Task { @MainActor in
                self.isProcessing = false
            }
        }
        
        var messages: [Chat.Message] = []
        
        if let system = systemPrompt, !system.isEmpty {
            messages.append(.system(system))
        }
        messages.append(.user(userPrompt))
        
        if streaming {
            return try await processStreaming(messages: messages)
        } else {
            return try await processNonStreaming(messages: messages)
        }
    }
    
    private func processStreaming(messages: [Chat.Message]) async throws -> String {
        let startTime = Date()
        var tokenCount = 0
        var fullResponse = ""
        
        let stream = try await client.chatStream(
            model: Model.ID(stringLiteral: selectedModel),
            messages: messages,
            keepAlive: .minutes(10)
        )
        
        for try await chunk in stream {
            let content = chunk.message.content
            if !content.isEmpty {
                fullResponse += content
                tokenCount += 1
                
                await MainActor.run {
                    self.currentOutput = fullResponse
                }
            }
            
            if chunk.done {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > 0 {
                    await MainActor.run {
                        self.tokensPerSecond = Double(tokenCount) / elapsed
                    }
                }
            }
        }
        
        return fullResponse
    }
    
    private func processNonStreaming(messages: [Chat.Message]) async throws -> String {
        let response = try await client.chat(
            model: Model.ID(stringLiteral: selectedModel),
            messages: messages,
            keepAlive: .minutes(10)
        )
        
        return response.message.content
    }
    
    /// Generate with thinking (for compatible models like deepseek-r1)
    func generateWithThinking(systemPrompt: String?, 
                               userPrompt: String) async throws -> (thinking: String?, response: String) {
        if !isConnected {
            _ = await checkConnection()
        }
        
        isProcessing = true
        defer { 
            Task { @MainActor in
                self.isProcessing = false
            }
        }
        
        var messages: [Chat.Message] = []
        if let system = systemPrompt {
            messages.append(.system(system))
        }
        messages.append(.user(userPrompt))
        
        let response = try await client.chat(
            model: Model.ID(stringLiteral: selectedModel),
            messages: messages,
            think: true,
            keepAlive: .minutes(10)
        )
        
        return (thinking: response.message.thinking, response: response.message.content)
    }
    
    /// Generate JSON structured output
    func generateJSON(systemPrompt: String?,
                      userPrompt: String,
                      schema: [String: Any]? = nil) async throws -> String {
        if !isConnected {
            _ = await checkConnection()
        }
        
        isProcessing = true
        defer {
            Task { @MainActor in
                self.isProcessing = false
            }
        }
        
        var messages: [Chat.Message] = []
        if let system = systemPrompt {
            messages.append(.system(system))
        }
        messages.append(.user(userPrompt))
        
        let response = try await client.chat(
            model: Model.ID(stringLiteral: selectedModel),
            messages: messages,
            format: "json",
            keepAlive: .minutes(10)
        )
        
        return response.message.content.isEmpty ? "{}" : response.message.content
    }
}
