import SwiftUI
import RoonSageCore

@main
struct RoonSageApp: App {
    @State private var client = RoonClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(client)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environment(client)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(client)
        } label: {
            Image(systemName: "music.note.house")
        }
        .menuBarExtraStyle(.window)
    }
}
