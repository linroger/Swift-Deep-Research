import Foundation

/// Represents a source citation from research
struct SourceCitation: Identifiable, Codable, Hashable {
    var id: String { url }
    let title: String
    let url: String
    let snippet: String?
}

/// A message in the chat conversation
struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let text: String
    let isUser: Bool
    let timestamp: Date
    var sources: [SourceCitation]
    var isStreaming: Bool
    
    init(text: String, 
         isUser: Bool,
         sources: [SourceCitation] = [],
         isStreaming: Bool = false) {
        self.id = UUID()
        self.text = text
        self.isUser = isUser
        self.timestamp = Date()
        self.sources = sources
        self.isStreaming = isStreaming
    }
    
    // For updating existing messages
    init(id: UUID,
         text: String,
         isUser: Bool,
         timestamp: Date,
         sources: [SourceCitation] = [],
         isStreaming: Bool = false) {
        self.id = id
        self.text = text
        self.isUser = isUser
        self.timestamp = timestamp
        self.sources = sources
        self.isStreaming = isStreaming
    }
} 
