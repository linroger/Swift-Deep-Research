import SwiftUI

struct ChatView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @EnvironmentObject var appState: AppState
    @State private var showingSidebar = true
    
    var body: some View {
        NavigationSplitView(columnVisibility: .constant(showingSidebar ? .all : .detailOnly)) {
            ConversationSidebar(viewModel: viewModel)
                .frame(minWidth: 200)
        } detail: {
            ChatDetailView(viewModel: viewModel, appState: appState)
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView(appState: appState)
        }
        .sheet(isPresented: $viewModel.showMemory) {
            NavigationStack {
                MemoryListView()
            }
            .frame(minWidth: 500, minHeight: 400)
        }
        .sheet(isPresented: $viewModel.showPromptEditor) {
            NavigationStack {
                PromptEditorView()
            }
            .frame(minWidth: 600, minHeight: 500)
        }
    }
}

// MARK: - Conversation Sidebar

struct ConversationSidebar: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var conversationManager = ConversationManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // New conversation button
            Button {
                viewModel.createNewConversation()
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("New Research")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            
            Divider()
            
            // Conversation list
            List(selection: Binding(
                get: { conversationManager.currentConversationId },
                set: { id in
                    if let id = id {
                        viewModel.selectConversation(id)
                    }
                }
            )) {
                ForEach(conversationManager.conversations) { conversation in
                    ConversationRow(conversation: conversation)
                        .tag(conversation.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                viewModel.deleteConversation(conversation.id)
                            }
                        }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("History")
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .lineLimit(1)
                .font(.body)
            
            HStack {
                Text("\(conversation.messages.count) messages")
                Spacer()
                Text(conversation.updatedAt.formatted(date: .abbreviated, time: .omitted))
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Chat Detail View

struct ChatDetailView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var appState: AppState
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar area
            ChatToolbar(viewModel: viewModel, appState: appState)
            
            Divider()
            
            // Messages area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageView(message: message, showSources: AppSettings.shared.showSources)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let lastMessage = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            // Research progress with detailed steps
            if viewModel.isResearching {
                VStack(spacing: 0) {
                    ResearchStepsView(progress: viewModel.researchProgress)
                        .padding(.horizontal)
                        .padding(.top, 8)
                    
                    ResearchProgressBar(progress: viewModel.researchProgress) {
                        viewModel.cancelResearch()
                    }
                }
            }
            
            Divider()
            
            // Input area
            ChatInputView(viewModel: viewModel, isInputFocused: _isInputFocused)
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

// MARK: - Chat Toolbar

struct ChatToolbar: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var appState: AppState
    
    var body: some View {
        HStack {
            // Provider indicator
            HStack(spacing: 6) {
                Image(systemName: appState.currentProviderType.icon)
                    .foregroundColor(.accentColor)
                Text(appState.currentProviderName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            
            Spacer()
            
            // Actions
            HStack(spacing: 8) {
                Button {
                    viewModel.showMemory = true
                } label: {
                    Image(systemName: "brain")
                }
                .help("Memory")
                
                Button {
                    viewModel.showPromptEditor = true
                } label: {
                    Image(systemName: "text.bubble")
                }
                .help("System Prompts")
                
                Button {
                    viewModel.clearMessages()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear Chat")
                
                Button {
                    viewModel.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Research Progress Bar

struct ResearchProgressBar: View {
    let progress: ResearchProgress
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                ProgressView()
                    .scaleEffect(0.7)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.phase.rawValue)
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    Text(progress.statusMessage)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    if progress.sourcesFound > 0 {
                        Label("\(progress.sourcesProcessed)/\(progress.sourcesFound)", systemImage: "doc.text")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Button("Cancel") {
                        onCancel()
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1))
    }
}

// MARK: - Chat Input

struct ChatInputView: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState var isInputFocused: Bool
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Text input
            TextField("Ask a research question...", text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .focused($isInputFocused)
                .onSubmit {
                    if !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        viewModel.sendMessage()
                    }
                }
            
            // Send/Stop button - smaller and more refined
            Button {
                if viewModel.isResearching {
                    viewModel.cancelResearch()
                } else {
                    viewModel.sendMessage()
                }
            } label: {
                Image(systemName: viewModel.isResearching ? "stop.fill" : "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        viewModel.isResearching ? Color.red : 
                        (viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 
                         Color.gray.opacity(0.5) : Color.accentColor)
                    )
                    .cornerRadius(14)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isResearching)
            .help(viewModel.isResearching ? "Stop research" : "Send message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Message View

struct MessageView: View {
    let message: ChatMessage
    let showSources: Bool
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.isUser {
                Spacer(minLength: 60)
            }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 8) {
                // Message content
                ChatBubbleView(message: message)
                
                // Sources
                if showSources && !message.sources.isEmpty && !message.isUser {
                    SourcesView(sources: message.sources)
                }
                
                // Timestamp
                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if !message.isUser {
                Spacer(minLength: 60)
            }
        }
    }
}

// MARK: - Sources View

struct SourcesView: View {
    let sources: [SourceCitation]
    @State private var isExpanded = true
    @ObservedObject private var settings = AppSettings.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed.fill")
                        .foregroundColor(.orange)
                    Text("\(sources.count) Sources")
                        .fontWeight(.medium)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .font(.system(size: settings.fontSize.captionSize))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        SourceRow(source: source, index: index + 1, fontSize: settings.fontSize)
                    }
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }
        }
    }
}

struct SourceRow: View {
    let source: SourceCitation
    let index: Int
    let fontSize: FontSize
    @State private var isHovering = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Index badge
            Text("\(index)")
                .font(.system(size: fontSize.captionSize - 2, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Color.orange)
                .cornerRadius(4)
            
            VStack(alignment: .leading, spacing: 2) {
                // Title
                Text(source.title)
                    .font(.system(size: fontSize.captionSize))
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundColor(.primary)
                
                // URL
                if let url = URL(string: source.url) {
                    Text(url.host ?? source.url)
                        .font(.system(size: fontSize.captionSize - 1))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Open link button
            Link(destination: URL(string: source.url) ?? URL(string: "https://example.com")!) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: fontSize.captionSize))
                    .foregroundColor(.accentColor)
            }
            .opacity(isHovering ? 1 : 0.6)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isHovering ? Color.accentColor.opacity(0.05) : Color.clear)
        .cornerRadius(4)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Preview

struct ChatView_Previews: PreviewProvider {
    static var previews: some View {
        ChatView()
            .environmentObject(ChatViewModel(
                searchService: SearchService(),
                webReaderService: WebContentExtractor.shared,
                llmProvider: AppState.shared.localLLMProvider
            ))
            .environmentObject(AppState.shared)
    }
}
