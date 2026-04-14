import Foundation
import SwiftUI
import Combine

@MainActor
class ChatViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isResearching: Bool = false
    @Published var researchProgress: ResearchProgress = .initial
    @Published var errorMessage: String? = nil
    @Published var showSettings: Bool = false
    @Published var showMemory: Bool = false
    @Published var showPromptEditor: Bool = false
    @Published var showConversations: Bool = false
    @Published var streamingText: String = ""
    
    // MARK: - Dependencies
    private let searchService: SearchServiceProtocol
    private let webReaderService: ContentExtractor
    
    // MARK: - Agent
    private var currentAgent: Agent?
    
    // MARK: - Managers
    private let conversationManager = ConversationManager.shared
    private let appState = AppState.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    init(searchService: SearchServiceProtocol,
         webReaderService: ContentExtractor,
         llmProvider: LLMProviderProtocol) {
        self.searchService = searchService
        self.webReaderService = webReaderService
        
        // Load current conversation messages
        loadCurrentConversation()
        
        // Observe conversation changes
        conversationManager.$currentConversationId
            .sink { [weak self] _ in
                self?.loadCurrentConversation()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Conversation Management
    
    private func loadCurrentConversation() {
        if let conversation = conversationManager.currentConversation {
            messages = conversation.messages
        } else {
            messages = []
        }
    }
    
    func createNewConversation() {
        conversationManager.createNewConversation()
        messages = []
        inputText = ""
        errorMessage = nil
    }
    
    func selectConversation(_ id: UUID) {
        conversationManager.selectConversation(id: id)
    }
    
    func deleteConversation(_ id: UUID) {
        conversationManager.deleteConversation(id: id)
    }
    
    // MARK: - Message Sending
    
    func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // Add user message
        let userMessage = ChatMessage(text: trimmed, isUser: true)
        messages.append(userMessage)
        conversationManager.addMessage(userMessage)
        
        inputText = ""
        isResearching = true
        errorMessage = nil
        streamingText = ""
        
        // Add placeholder for response
        let placeholderMessage = ChatMessage(text: "", isUser: false, isStreaming: true)
        messages.append(placeholderMessage)
        
        Task {
            await performResearch(for: trimmed)
        }
    }
    
    // MARK: - Research
    
    private func performResearch(for question: String) async {
        do {
            // Create agent with current provider and system prompt
            let agent = Agent(
                searchService: searchService,
                webReaderService: webReaderService,
                llmProvider: appState.activeLLMProvider,
                systemPrompt: appState.getSystemPrompt(),
                config: .default
            )
            
            currentAgent = agent
            
            // Set up progress updates
            agent.onProgressUpdate = { [weak self] progress in
                Task { @MainActor in
                    self?.researchProgress = progress
                    // Only update streaming message with status, not progress message
                    if progress.phase != .complete {
                        self?.updateStreamingMessage(progress.statusMessage)
                    }
                }
            }
            
            // Set up streaming updates
            agent.onStreamingUpdate = { [weak self] text in
                Task { @MainActor in
                    self?.updateStreamingMessage(text)
                }
            }
            
            // Perform research
            let answer = try await agent.getResponse(for: question)
            let sources = agent.sources
            
            // Ensure we're on main actor and replace with final answer
            await MainActor.run {
                // Create final message with the answer
                let finalMessage = ChatMessage(
                    text: answer,
                    isUser: false,
                    sources: sources,
                    isStreaming: false
                )
                
                // Replace the last message (placeholder) with the final answer
                if !messages.isEmpty && !messages[messages.count - 1].isUser {
                    messages[messages.count - 1] = finalMessage
                    conversationManager.addMessage(finalMessage)
                } else {
                    messages.append(finalMessage)
                    conversationManager.addMessage(finalMessage)
                }
                
                // Force UI refresh
                objectWillChange.send()
            }
            
        } catch is CancellationError {
            await MainActor.run {
                replaceLastMessage(with: ChatMessage(
                    text: "Research was cancelled.",
                    isUser: false
                ))
            }
        } catch ResearchError.cancelled {
            await MainActor.run {
                replaceLastMessage(with: ChatMessage(
                    text: "Research was cancelled.",
                    isUser: false
                ))
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                replaceLastMessage(with: ChatMessage(
                    text: "Error: \(error.localizedDescription)",
                    isUser: false
                ))
            }
        }
        
        await MainActor.run {
            isResearching = false
            currentAgent = nil
            researchProgress = .initial
        }
    }
    
    private func updateStreamingMessage(_ text: String) {
        streamingText = text
        if !messages.isEmpty {
            let lastIndex = messages.count - 1
            if !messages[lastIndex].isUser {
                messages[lastIndex] = ChatMessage(
                    id: messages[lastIndex].id,
                    text: text,
                    isUser: false,
                    timestamp: messages[lastIndex].timestamp,
                    isStreaming: true
                )
            }
        }
    }
    
    private func replaceLastMessage(with message: ChatMessage) {
        if !messages.isEmpty {
            messages.removeLast()
        }
        messages.append(message)
        conversationManager.addMessage(message)
    }
    
    // MARK: - Cancel Research
    
    func cancelResearch() {
        currentAgent?.cancel()
        isResearching = false
        
        if !messages.isEmpty && messages.last?.isUser == false {
            replaceLastMessage(with: ChatMessage(
                text: "Research cancelled.",
                isUser: false
            ))
        }
    }
    
    // MARK: - Quick Actions
    
    func regenerateLastResponse() {
        guard messages.count >= 2 else { return }
        
        // Find last user message
        var lastUserMessageIndex: Int?
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            if messages[i].isUser {
                lastUserMessageIndex = i
                break
            }
        }
        
        guard let userIndex = lastUserMessageIndex else { return }
        
        let question = messages[userIndex].text
        
        // Remove messages after user message
        messages = Array(messages.prefix(userIndex + 1))
        
        // Re-run research
        isResearching = true
        let placeholderMessage = ChatMessage(text: "", isUser: false, isStreaming: true)
        messages.append(placeholderMessage)
        
        Task {
            await performResearch(for: question)
        }
    }
    
    func clearMessages() {
        messages = []
        createNewConversation()
    }
}
