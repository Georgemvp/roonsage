import RoonSageCore
import RoonSageUI
import SwiftUI

@MainActor
@main
struct RoonSageAnalyzerApp: App {
    @State private var model = AnalyzerModel()
    @State private var updater = AnalyzerUpdater()
    @State private var client: RoonClient

    init() {
        // Register as the distinct "RoonSage Server" Roon extension before the
        // shared client is touched, so we don't clash with the client apps.
        RoonClient.useServerIdentity()
        _client = State(initialValue: RoonClient.shared)
    }

    var body: some Scene {
        Window("RoonSage Analyzer", id: "main") {
            TabView {
                AnalyzerView()
                    .tabItem { Label("Analyzer", systemImage: "waveform.path.ecg") }
                // The server's full config surface — this is the single place to
                // configure Roon, LLM, Last.fm, ListenBrainz, Qobuz, analyzer.
                NavigationStack { SettingsView(role: .server) }
                    .tabItem { Label("Server", systemImage: "gearshape") }
            }
            .environment(model)
            .environment(updater)
            .environment(client)
            .frame(minWidth: 560, minHeight: 640)
            .task { await updater.checkOnLaunch() }
            .task { model.autoStartIfEnabled() }
            .task { model.startServingIfNeeded() }
            // This app IS the server: connect to Roon on launch so the library
            // sync can run and the share server (5767) serves a populated DB.
            // The share server auto-starts via RoonClient init.
            .task { await connectRoon() }
        }
        .windowResizability(.contentSize)
    }

    private func connectRoon() async {
        if let host = client.savedHost {
            await client.connect(host: host, port: client.savedPort)
        } else {
            await client.discoverAndConnect()
        }
    }
}
