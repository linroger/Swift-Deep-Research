import Foundation

/// A single memory entry that the AI can create and update
struct MemoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var content: String
    var category: MemoryCategory
    var createdAt: Date
    var updatedAt: Date
    var importance: MemoryImportance
    var tags: [String]
    
    init(content: String, 
         category: MemoryCategory = .general,
         importance: MemoryImportance = .normal,
         tags: [String] = []) {
        self.id = UUID()
        self.content = content
        self.category = category
        self.createdAt = Date()
        self.updatedAt = Date()
        self.importance = importance
        self.tags = tags
    }
}

/// Categories for organizing memories
enum MemoryCategory: String, Codable, CaseIterable {
    case general = "General"
    case userPreference = "User Preference"
    case projectContext = "Project Context"
    case researchInsight = "Research Insight"
    case correction = "Correction"
    case instruction = "Instruction"
    
    var icon: String {
        switch self {
        case .general: return "brain.head.profile"
        case .userPreference: return "person.fill"
        case .projectContext: return "folder.fill"
        case .researchInsight: return "lightbulb.fill"
        case .correction: return "exclamationmark.triangle.fill"
        case .instruction: return "list.bullet.clipboard"
        }
    }
}

/// Importance levels for memories
enum MemoryImportance: Int, Codable, CaseIterable, Comparable {
    case low = 1
    case normal = 2
    case high = 3
    case critical = 4
    
    var displayName: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }
    
    static func < (lhs: MemoryImportance, rhs: MemoryImportance) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Manager for AI memory system
@MainActor
class MemoryManager: ObservableObject {
    static let shared = MemoryManager()
    
    @Published var memories: [MemoryEntry] = []
    @Published var isEnabled: Bool = true
    
    private let storageKey = "ai_memories"
    private let maxMemories = 100
    
    private init() {
        loadMemories()
    }
    
    /// Add a new memory
    func addMemory(_ content: String, 
                   category: MemoryCategory = .general,
                   importance: MemoryImportance = .normal,
                   tags: [String] = []) {
        let memory = MemoryEntry(content: content, 
                                  category: category, 
                                  importance: importance, 
                                  tags: tags)
        memories.insert(memory, at: 0)
        trimMemoriesIfNeeded()
        saveMemories()
    }
    
    /// Update an existing memory
    func updateMemory(id: UUID, content: String) {
        if let index = memories.firstIndex(where: { $0.id == id }) {
            memories[index].content = content
            memories[index].updatedAt = Date()
            saveMemories()
        }
    }
    
    /// Delete a memory
    func deleteMemory(id: UUID) {
        memories.removeAll { $0.id == id }
        saveMemories()
    }
    
    /// Clear all memories
    func clearAllMemories() {
        memories = []
        saveMemories()
    }
    
    /// Get memories by category
    func memories(for category: MemoryCategory) -> [MemoryEntry] {
        memories.filter { $0.category == category }
    }
    
    /// Get memories by tag
    func memories(withTag tag: String) -> [MemoryEntry] {
        memories.filter { $0.tags.contains(tag) }
    }
    
    /// Get most important memories (for context injection)
    func topMemories(count: Int = 10) -> [MemoryEntry] {
        memories
            .sorted { $0.importance > $1.importance }
            .prefix(count)
            .map { $0 }
    }
    
    /// Format memories for system prompt injection
    func formatForPrompt() -> String {
        guard isEnabled && !memories.isEmpty else { return "" }
        
        let topMemories = topMemories(count: 15)
        var formatted = "\n\n## Your Memory (Information you've learned about the user and context):\n"
        
        for memory in topMemories {
            let importance = memory.importance == .critical ? "IMPORTANT: " : ""
            formatted += "- [\(memory.category.rawValue)] \(importance)\(memory.content)\n"
        }
        
        return formatted
    }
    
    /// Parse AI response for memory updates
    func parseAndUpdateFromResponse(_ response: String) {
        // Look for memory update markers in the response
        let memoryPattern = #"\[MEMORY:(\w+)\](.*?)\[\/MEMORY\]"#
        
        guard let regex = try? NSRegularExpression(pattern: memoryPattern, options: [.dotMatchesLineSeparators]) else {
            return
        }
        
        let range = NSRange(response.startIndex..., in: response)
        let matches = regex.matches(in: response, options: [], range: range)
        
        for match in matches {
            guard match.numberOfRanges >= 3,
                  let categoryRange = Range(match.range(at: 1), in: response),
                  let contentRange = Range(match.range(at: 2), in: response) else {
                continue
            }
            
            let categoryStr = String(response[categoryRange]).lowercased()
            let content = String(response[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            
            let category: MemoryCategory
            switch categoryStr {
            case "preference": category = .userPreference
            case "project": category = .projectContext
            case "insight": category = .researchInsight
            case "correction": category = .correction
            case "instruction": category = .instruction
            default: category = .general
            }
            
            addMemory(content, category: category)
        }
    }
    
    // MARK: - Persistence
    
    private func saveMemories() {
        do {
            let data = try JSONEncoder().encode(memories)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            print("Failed to save memories: \(error)")
        }
    }
    
    private func loadMemories() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        
        do {
            memories = try JSONDecoder().decode([MemoryEntry].self, from: data)
        } catch {
            print("Failed to load memories: \(error)")
            memories = []
        }
    }
    
    private func trimMemoriesIfNeeded() {
        if memories.count > maxMemories {
            // Keep highest importance memories
            let sorted = memories.sorted { $0.importance > $1.importance }
            memories = Array(sorted.prefix(maxMemories))
        }
    }
}

/// Extension for importing/exporting memories
extension MemoryManager {
    func exportMemories() -> Data? {
        try? JSONEncoder().encode(memories)
    }
    
    func importMemories(from data: Data) throws {
        let imported = try JSONDecoder().decode([MemoryEntry].self, from: data)
        memories.append(contentsOf: imported)
        trimMemoriesIfNeeded()
        saveMemories()
    }
}
