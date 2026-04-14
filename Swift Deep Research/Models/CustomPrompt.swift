import Foundation

/// A custom system prompt that users can create and edit
struct CustomPrompt: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var content: String
    var isDefault: Bool
    var createdAt: Date
    var updatedAt: Date
    
    init(name: String, content: String, isDefault: Bool = false) {
        self.id = UUID()
        self.name = name
        self.content = content
        self.isDefault = isDefault
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

/// Manager for custom system prompts
@MainActor
class CustomPromptManager: ObservableObject {
    static let shared = CustomPromptManager()
    
    @Published var prompts: [CustomPrompt] = []
    @Published var selectedPromptId: UUID?
    
    private let storageKey = "custom_prompts"
    private let selectedPromptKey = "selected_prompt_id"
    
    var selectedPrompt: CustomPrompt? {
        guard let id = selectedPromptId else { return defaultResearchPrompt }
        return prompts.first { $0.id == id } ?? defaultResearchPrompt
    }
    
    private init() {
        loadPrompts()
        loadSelectedPrompt()
        
        // Add default prompts if empty
        if prompts.isEmpty {
            createDefaultPrompts()
        }
    }
    
    // MARK: - Default Prompts
    
    private let defaultResearchPrompt = CustomPrompt(
        name: "Deep Research Assistant",
        content: """
        You are an advanced research assistant with expertise in deep, multi-step research and analysis. Your capabilities include:

        1. **Thorough Research**: You systematically explore topics using web searches, analyzing multiple sources to build comprehensive understanding.

        2. **Critical Analysis**: You evaluate sources for credibility, cross-reference information, and identify potential biases or gaps.

        3. **Structured Thinking**: You use chain-of-thought reasoning, breaking complex questions into manageable sub-questions.

        4. **Evidence-Based Responses**: You cite specific evidence from sources, using exact quotes when appropriate. You never fabricate information.

        5. **Honest Uncertainty**: When information is incomplete or conflicting, you acknowledge uncertainty rather than guessing.

        6. **Memory & Context**: You can remember important information about the user and their projects to provide more personalized assistance.

        When researching:
        - Start by understanding what information is needed
        - Generate relevant search queries
        - Analyze search results critically
        - Synthesize findings into clear, well-organized responses
        - Cite sources and provide references

        If you learn something important about the user or their preferences, you can save it to memory using the format:
        [MEMORY:category]content[/MEMORY]

        Categories: preference, project, insight, correction, instruction, general
        """,
        isDefault: true
    )
    
    private func createDefaultPrompts() {
        prompts = [
            defaultResearchPrompt,
            CustomPrompt(
                name: "Concise Researcher",
                content: """
                You are a research assistant focused on providing concise, actionable answers. 
                
                Guidelines:
                - Be brief but comprehensive
                - Use bullet points for clarity
                - Prioritize the most relevant information
                - Cite sources inline
                - Avoid unnecessary elaboration
                """,
                isDefault: false
            ),
            CustomPrompt(
                name: "Academic Research",
                content: """
                You are an academic research assistant. Your responses should:
                
                1. Follow academic standards and conventions
                2. Use proper citation formats
                3. Distinguish between primary and secondary sources
                4. Evaluate methodology and evidence quality
                5. Present balanced perspectives on controversial topics
                6. Use formal, scholarly language
                7. Identify gaps in existing research
                """,
                isDefault: false
            ),
            CustomPrompt(
                name: "Technical Research",
                content: """
                You are a technical research assistant specializing in technology, programming, and engineering topics.
                
                Focus on:
                - Code examples and implementation details
                - Best practices and design patterns
                - Performance considerations
                - Security implications
                - Compatibility and dependencies
                - Official documentation references
                
                Provide practical, actionable technical guidance with code snippets when relevant.
                """,
                isDefault: false
            )
        ]
        savePrompts()
    }
    
    // MARK: - CRUD Operations
    
    func addPrompt(name: String, content: String) {
        let prompt = CustomPrompt(name: name, content: content)
        prompts.append(prompt)
        savePrompts()
    }
    
    func updatePrompt(id: UUID, name: String, content: String) {
        if let index = prompts.firstIndex(where: { $0.id == id }) {
            prompts[index].name = name
            prompts[index].content = content
            prompts[index].updatedAt = Date()
            savePrompts()
        }
    }
    
    func deletePrompt(id: UUID) {
        prompts.removeAll { $0.id == id }
        if selectedPromptId == id {
            selectedPromptId = prompts.first?.id
        }
        savePrompts()
    }
    
    func selectPrompt(id: UUID?) {
        selectedPromptId = id
        saveSelectedPrompt()
    }
    
    func duplicatePrompt(id: UUID) {
        guard let original = prompts.first(where: { $0.id == id }) else { return }
        let copy = CustomPrompt(name: "\(original.name) (Copy)", content: original.content)
        prompts.append(copy)
        savePrompts()
    }
    
    func resetToDefaults() {
        prompts = []
        createDefaultPrompts()
        selectedPromptId = prompts.first?.id
        saveSelectedPrompt()
    }
    
    // MARK: - Persistence
    
    private func savePrompts() {
        do {
            let data = try JSONEncoder().encode(prompts)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            print("Failed to save prompts: \(error)")
        }
    }
    
    private func loadPrompts() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        
        do {
            prompts = try JSONDecoder().decode([CustomPrompt].self, from: data)
        } catch {
            print("Failed to load prompts: \(error)")
            prompts = []
        }
    }
    
    private func saveSelectedPrompt() {
        if let id = selectedPromptId {
            UserDefaults.standard.set(id.uuidString, forKey: selectedPromptKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedPromptKey)
        }
    }
    
    private func loadSelectedPrompt() {
        guard let idString = UserDefaults.standard.string(forKey: selectedPromptKey),
              let id = UUID(uuidString: idString) else {
            selectedPromptId = prompts.first?.id
            return
        }
        selectedPromptId = id
    }
}
