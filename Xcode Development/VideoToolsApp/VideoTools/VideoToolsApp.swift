import SwiftUI

@main
struct VideoToolsApp: App {
    @State private var appState = AppState()
    @State private var playerManager = MediaPlayerManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(playerManager)
        }
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
