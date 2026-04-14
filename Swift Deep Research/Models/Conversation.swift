import Foundation

/// Represents a conversation/chat session
struct Conversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date
    var systemPromptId: UUID?
    
    init(title: String = "New Research", systemPromptId: UUID? = nil) {
        self.id = UUID()
        self.title = title
        self.messages = []
        self.createdAt = Date()
        self.updatedAt = Date()
        self.systemPromptId = systemPromptId
    }
    
    mutating func addMessage(_ message: ChatMessage) {
        messages.append(message)
        updatedAt = Date()
    }
    
    mutating func updateTitle(_ newTitle: String) {
        title = newTitle
        updatedAt = Date()
    }
}

/// Manager for conversation history
@MainActor
class ConversationManager: ObservableObject {
    static let shared = ConversationManager()
    
    @Published var conversations: [Conversation] = []
    @Published var currentConversationId: UUID?
    
    private let storageKey = "conversations"
    private let maxConversations = 50
    
    var currentConversation: Conversation? {
        get {
            guard let id = currentConversationId else { return nil }
            return conversations.first { $0.id == id }
        }
        set {
            if let newValue = newValue,
               let index = conversations.firstIndex(where: { $0.id == newValue.id }) {
                conversations[index] = newValue
                saveConversations()
            }
        }
    }
    
    private init() {
        loadConversations()
        
        // Create a new conversation if none exist
        if conversations.isEmpty {
            _ = createNewConversation()
        } else {
            currentConversationId = conversations.first?.id
        }
    }
    
    // MARK: - Conversation Management
    
    @discardableResult
    func createNewConversation(title: String = "New Research") -> Conversation {
        let conversation = Conversation(
            title: title,
            systemPromptId: CustomPromptManager.shared.selectedPromptId
        )
        conversations.insert(conversation, at: 0)
        currentConversationId = conversation.id
        trimConversationsIfNeeded()
        saveConversations()
        return conversation
    }
    
    func selectConversation(id: UUID) {
        currentConversationId = id
    }
    
    func deleteConversation(id: UUID) {
        conversations.removeAll { $0.id == id }
        
        if currentConversationId == id {
            currentConversationId = conversations.first?.id
            if currentConversationId == nil {
                _ = createNewConversation()
            }
        }
        
        saveConversations()
    }
    
    func clearAllConversations() {
        conversations = []
        _ = createNewConversation()
    }
    
    func addMessage(_ message: ChatMessage, toConversation id: UUID? = nil) {
        let targetId = id ?? currentConversationId
        guard let targetId = targetId,
              let index = conversations.firstIndex(where: { $0.id == targetId }) else {
            return
        }
        
        conversations[index].addMessage(message)
        
        // Auto-generate title from first user message if still default
        if conversations[index].title == "New Research",
           message.isUser,
           conversations[index].messages.filter({ $0.isUser }).count == 1 {
            let title = generateTitle(from: message.text)
            conversations[index].updateTitle(title)
        }
        
        saveConversations()
    }
    
    func updateLastMessage(text: String, inConversation id: UUID? = nil) {
        let targetId = id ?? currentConversationId
        guard let targetId = targetId,
              let index = conversations.firstIndex(where: { $0.id == targetId }),
              !conversations[index].messages.isEmpty else {
            return
        }
        
        let lastIndex = conversations[index].messages.count - 1
        conversations[index].messages[lastIndex] = ChatMessage(
            id: conversations[index].messages[lastIndex].id,
            text: text,
            isUser: conversations[index].messages[lastIndex].isUser,
            timestamp: conversations[index].messages[lastIndex].timestamp,
            sources: conversations[index].messages[lastIndex].sources,
            isStreaming: conversations[index].messages[lastIndex].isStreaming
        )
        conversations[index].updatedAt = Date()
        saveConversations()
    }
    
    // MARK: - Helpers
    
    private func generateTitle(from text: String) -> String {
        let words = text.split(separator: " ").prefix(6).joined(separator: " ")
        if words.count > 40 {
            return String(words.prefix(40)) + "..."
        }
        return words.isEmpty ? "New Research" : words
    }
    
    private func trimConversationsIfNeeded() {
        if conversations.count > maxConversations {
            conversations = Array(conversations.prefix(maxConversations))
        }
    }
    
    // MARK: - Persistence
    
    private func saveConversations() {
        do {
            let data = try JSONEncoder().encode(conversations)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            print("Failed to save conversations: \(error)")
        }
    }
    
    private func loadConversations() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        
        do {
            conversations = try JSONDecoder().decode([Conversation].self, from: data)
            // Sort by most recent
            conversations.sort { $0.updatedAt > $1.updatedAt }
        } catch {
            print("Failed to load conversations: \(error)")
            conversations = []
        }
    }
}
