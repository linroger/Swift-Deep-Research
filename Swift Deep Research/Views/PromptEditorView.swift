import SwiftUI

struct PromptEditorView: View {
    @ObservedObject var promptManager = CustomPromptManager.shared
    @State private var showingAddPrompt = false
    @State private var editingPrompt: CustomPrompt?
    @State private var showingResetConfirmation = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header info
            VStack(alignment: .leading, spacing: 8) {
                Text("System prompts define how the AI assistant behaves during research.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if let selected = promptManager.selectedPrompt {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Active: \(selected.name)")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Prompt list
            List(selection: Binding(
                get: { promptManager.selectedPromptId },
                set: { promptManager.selectPrompt(id: $0) }
            )) {
                ForEach(promptManager.prompts) { prompt in
                    PromptRowView(prompt: prompt, isSelected: promptManager.selectedPromptId == prompt.id)
                        .tag(prompt.id)
                        .contextMenu {
                            Button("Edit") {
                                editingPrompt = prompt
                            }
                            
                            Button("Duplicate") {
                                promptManager.duplicatePrompt(id: prompt.id)
                            }
                            
                            Divider()
                            
                            Button("Delete", role: .destructive) {
                                promptManager.deletePrompt(id: prompt.id)
                            }
                            .disabled(prompt.isDefault)
                        }
                }
            }
        }
        .navigationTitle("System Prompts")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingResetConfirmation = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Reset to defaults")
                
                Button {
                    showingAddPrompt = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddPrompt) {
            PromptEditSheet(mode: .add)
        }
        .sheet(item: $editingPrompt) { prompt in
            PromptEditSheet(mode: .edit(prompt))
        }
        .alert("Reset to Defaults?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                promptManager.resetToDefaults()
            }
        } message: {
            Text("This will delete all custom prompts and restore the default prompts.")
        }
    }
}

struct PromptRowView: View {
    let prompt: CustomPrompt
    let isSelected: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
                
                Text(prompt.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                
                if prompt.isDefault {
                    Text("Default")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(4)
                }
                
                Spacer()
                
                Text(prompt.updatedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(prompt.content)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

enum PromptEditMode: Identifiable {
    case add
    case edit(CustomPrompt)
    
    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let prompt): return prompt.id.uuidString
        }
    }
}

struct PromptEditSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var promptManager = CustomPromptManager.shared
    
    let mode: PromptEditMode
    
    @State private var name: String
    @State private var content: String
    
    init(mode: PromptEditMode) {
        self.mode = mode
        
        switch mode {
        case .add:
            _name = State(initialValue: "")
            _content = State(initialValue: "")
        case .edit(let prompt):
            _name = State(initialValue: prompt.name)
            _content = State(initialValue: prompt.content)
        }
    }
    
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(mode.id == "add" ? "New System Prompt" : "Edit System Prompt")
                    .font(.headline)
                Spacer()
            }
            
            Form {
                Section("Name") {
                    TextField("Prompt Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                
                Section("System Prompt Content") {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 300)
                }
                
                Section("Tips") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("• Define the AI's role and expertise")
                        Text("• Specify how responses should be formatted")
                        Text("• Include guidelines for citations and sources")
                        Text("• Set expectations for tone and detail level")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                if case .edit = mode {
                    Button("Preview") {
                        // Could show a preview of how the prompt would affect responses
                    }
                    .disabled(true) // Placeholder for future feature
                }
                
                Button(mode.id == "add" ? "Create Prompt" : "Save Changes") {
                    switch mode {
                    case .add:
                        promptManager.addPrompt(name: name, content: content)
                    case .edit(let prompt):
                        promptManager.updatePrompt(id: prompt.id, name: name, content: content)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 500)
    }
}

// MARK: - Prompt Template Suggestions

struct PromptTemplatePicker: View {
    @Binding var selectedContent: String
    @Environment(\.dismiss) var dismiss
    
    let templates = [
        ("Research Assistant", """
        You are an expert research assistant. Analyze information thoroughly and provide accurate, well-sourced answers.
        
        Guidelines:
        - Use only information from provided sources
        - Cite evidence with direct quotes
        - Acknowledge uncertainty
        - Think step-by-step
        """),
        ("Technical Expert", """
        You are a technical expert assistant specializing in software development and technology.
        
        Focus on:
        - Code examples and implementation details
        - Best practices and design patterns
        - Performance and security considerations
        - Official documentation references
        """),
        ("Academic Researcher", """
        You are an academic research assistant following scholarly standards.
        
        Requirements:
        - Use proper citation formats
        - Evaluate source credibility
        - Present balanced perspectives
        - Use formal, scholarly language
        """),
        ("Creative Writer", """
        You are a creative writing assistant with expertise in storytelling and content creation.
        
        Approach:
        - Use engaging, vivid language
        - Structure content for readability
        - Adapt tone to the context
        - Provide creative suggestions
        """)
    ]
    
    var body: some View {
        VStack {
            Text("Choose a Template")
                .font(.headline)
            
            List {
                ForEach(templates, id: \.0) { template in
                    Button {
                        selectedContent = template.1
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(template.0)
                                .fontWeight(.medium)
                            Text(template.1)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Button("Cancel") {
                dismiss()
            }
            .padding()
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}
