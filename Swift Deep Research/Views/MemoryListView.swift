import SwiftUI

struct MemoryListView: View {
    @ObservedObject var memoryManager = MemoryManager.shared
    @State private var selectedCategory: MemoryCategory?
    @State private var searchText = ""
    @State private var showingAddMemory = false
    @State private var editingMemory: MemoryEntry?
    
    var filteredMemories: [MemoryEntry] {
        var memories = memoryManager.memories
        
        if let category = selectedCategory {
            memories = memories.filter { $0.category == category }
        }
        
        if !searchText.isEmpty {
            memories = memories.filter { 
                $0.content.localizedCaseInsensitiveContains(searchText) ||
                $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
        
        return memories.sorted { $0.updatedAt > $1.updatedAt }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search memories...", text: $searchText)
                    .textFieldStyle(.plain)
                
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding()
            
            // Category filter
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    CategoryFilterButton(
                        title: "All",
                        icon: "tray.full",
                        isSelected: selectedCategory == nil
                    ) {
                        selectedCategory = nil
                    }
                    
                    ForEach(MemoryCategory.allCases, id: \.self) { category in
                        CategoryFilterButton(
                            title: category.rawValue,
                            icon: category.icon,
                            isSelected: selectedCategory == category
                        ) {
                            selectedCategory = category
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 8)
            
            Divider()
            
            // Memory list
            if filteredMemories.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "brain")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No memories yet")
                        .font(.headline)
                    Text("Memories are created automatically as you interact with the AI, or you can add them manually.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredMemories) { memory in
                        MemoryRowView(memory: memory)
                            .contextMenu {
                                Button("Edit") {
                                    editingMemory = memory
                                }
                                Button("Delete", role: .destructive) {
                                    memoryManager.deleteMemory(id: memory.id)
                                }
                            }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            memoryManager.deleteMemory(id: filteredMemories[index].id)
                        }
                    }
                }
            }
        }
        .navigationTitle("Memories")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddMemory = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddMemory) {
            AddMemorySheet()
        }
        .sheet(item: $editingMemory) { memory in
            EditMemorySheet(memory: memory)
        }
    }
}

struct CategoryFilterButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

struct MemoryRowView: View {
    let memory: MemoryEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: memory.category.icon)
                    .foregroundColor(.accentColor)
                
                Text(memory.category.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                ImportanceBadge(importance: memory.importance)
                
                Text(memory.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Text(memory.content)
                .font(.body)
                .lineLimit(3)
            
            if !memory.tags.isEmpty {
                HStack {
                    ForEach(memory.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ImportanceBadge: View {
    let importance: MemoryImportance
    
    var color: Color {
        switch importance {
        case .low: return .gray
        case .normal: return .blue
        case .high: return .orange
        case .critical: return .red
        }
    }
    
    var body: some View {
        Text(importance.displayName)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

struct AddMemorySheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var memoryManager = MemoryManager.shared
    
    @State private var content = ""
    @State private var category: MemoryCategory = .general
    @State private var importance: MemoryImportance = .normal
    @State private var tagsText = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Add Memory")
                .font(.headline)
            
            Form {
                Section("Content") {
                    TextEditor(text: $content)
                        .frame(minHeight: 100)
                }
                
                Section("Classification") {
                    Picker("Category", selection: $category) {
                        ForEach(MemoryCategory.allCases, id: \.self) { cat in
                            HStack {
                                Image(systemName: cat.icon)
                                Text(cat.rawValue)
                            }
                            .tag(cat)
                        }
                    }
                    
                    Picker("Importance", selection: $importance) {
                        ForEach(MemoryImportance.allCases, id: \.self) { imp in
                            Text(imp.displayName).tag(imp)
                        }
                    }
                }
                
                Section("Tags (comma-separated)") {
                    TextField("e.g., swift, coding, preferences", text: $tagsText)
                }
            }
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button("Add Memory") {
                    let tags = tagsText.split(separator: ",").map { 
                        String($0).trimmingCharacters(in: .whitespaces) 
                    }.filter { !$0.isEmpty }
                    
                    memoryManager.addMemory(
                        content,
                        category: category,
                        importance: importance,
                        tags: tags
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 450, minHeight: 400)
    }
}

struct EditMemorySheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var memoryManager = MemoryManager.shared
    
    let memory: MemoryEntry
    @State private var content: String
    
    init(memory: MemoryEntry) {
        self.memory = memory
        _content = State(initialValue: memory.content)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Memory")
                .font(.headline)
            
            Form {
                Section("Content") {
                    TextEditor(text: $content)
                        .frame(minHeight: 100)
                }
                
                Section("Info") {
                    HStack {
                        Text("Category")
                        Spacer()
                        Text(memory.category.rawValue)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Created")
                        Spacer()
                        Text(memory.createdAt.formatted())
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button("Save Changes") {
                    memoryManager.updateMemory(id: memory.id, content: content)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 450, minHeight: 350)
    }
}
