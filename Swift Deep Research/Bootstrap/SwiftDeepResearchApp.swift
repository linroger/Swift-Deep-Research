import SwiftUI
import SwiftData

@main
struct SwiftDeepResearchApp: App {
    @State private var env: AppEnvironment
    private let container: ModelContainer

    init() {
        do {
            let container = try ResearchStore.makeContainer()
            self.container = container
            let store = ResearchStore(container: container)
            _env = State(initialValue: AppEnvironment(store: store))
        } catch {
            fatalError("Failed to create research model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MainScene()
                .environment(env)
                .modelContainer(container)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Research") {
                    env.live = nil
                    env.selectedSessionID = nil
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
