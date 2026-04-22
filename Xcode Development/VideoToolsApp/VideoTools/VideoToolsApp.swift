import SwiftUI
import SwiftData

@main
struct VideoToolsApp: App {
    @State private var appState = AppState()
    @State private var playerManager = MediaPlayerManager()
    @State private var toolSettings = ToolSettingsViewModel()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(appState)
                .environment(playerManager)
                .environment(toolSettings)
        }
        .modelContainer(for: AppSettings.self)
        .windowStyle(.automatic)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
        
        Settings {
            SettingsView()
        }
    }
}

private struct AppRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(ToolSettingsViewModel.self) private var toolSettings

    var body: some View {
        ContentView()
            .task {
                toolSettings.configure(modelContext: modelContext, appState: appState)
            }
    }
}
