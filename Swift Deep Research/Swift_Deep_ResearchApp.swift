import SwiftUI
import MLX

@main
struct SwiftDeepResearchApp: App {
    @StateObject private var appState = AppState.shared
    
    init() {
        // Configure MLX GPU memory
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
        
        // Initialize Ollama connection check on startup
        Task { @MainActor in
            await AppState.shared.ollamaProvider.checkConnection()
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(createChatViewModel())
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Research") {
                    ConversationManager.shared.createNewConversation()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            
            CommandGroup(after: .sidebar) {
                Button("Show Memory") {
                    // Would need to trigger from view model
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                
                Button("Show Prompts") {
                    // Would need to trigger from view model
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        
        Settings {
            SettingsView(appState: appState)
        }
    }
    
    private func createChatViewModel() -> ChatViewModel {
        ChatViewModel(
            searchService: SearchService(),
            webReaderService: WebContentExtractor.shared,
            llmProvider: appState.activeLLMProvider
        )
    }
}

extension WebContentExtractor {
    static let shared = WebContentExtractor()
}
