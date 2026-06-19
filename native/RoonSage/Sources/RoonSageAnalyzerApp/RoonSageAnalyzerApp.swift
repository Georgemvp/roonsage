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
            // Sidebar navigation: Dashboard · Analyzer · Radio's · Server. The
            // server's full config (Roon, LLM, Last.fm, Qobuz, analyzer) lives under
            // the Server item; the new Radio's item controls the Qobuz radio mirror.
            AnalyzerRootView()
            .environment(model)
            .environment(updater)
            .environment(client)
            .frame(minWidth: 860, minHeight: 640)
            .task { await updater.checkOnLaunch() }
            .task { model.autoStartIfEnabled() }
            .task { model.startServingIfNeeded() }
            // This app IS the server: connect to Roon on launch so the library
            // sync can run and the share server (5767) serves a populated DB.
            // The share server auto-starts via RoonClient init.
            .task { await connectRoon() }
            .task { await lastfmSyncLoop() }
            // The server keeps the AI artist radios fresh on Qobuz (every 3h).
            .task { client.startArtistRadioRefresh() }
            // Pull analyzed features (tags/year/embeddings) into library.db so they
            // reach the library without the manual Settings "Sync features" button.
            .task { client.startServerFeatureSync() }
        }
        .windowResizability(.contentSize)
    }

    /// Haalt elke 15 minuten nieuwe Last.fm-scrobbles op (inclusief ARC-plays die
    /// Roon naar Last.fm heeft doorgestuurd). Start direct bij app-launch.
    private func lastfmSyncLoop() async {
        while !Task.isCancelled {
            await client.syncRecentLastfmScrobbles()
            try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
        }
    }

    /// The server must stay connected to Roon. Keep (re)trying from a not-
    /// connected state: saved host → localhost (the server usually runs on the
    /// Core machine) → SOOD discovery. A handshake that drops before
    /// authorization leaves RoonClient `.disconnected` without auto-reconnect,
    /// so we drive the retry here.
    private func connectRoon() async {
        var triedDiscovery = false
        while !Task.isCancelled {
            switch client.connectionState {
            case .connected, .connecting, .awaitingAuthorization, .discovering:
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            default:
                break   // .disconnected / .failed → (re)try
            }
            if let host = client.savedHost {
                await client.connect(host: host, port: client.savedPort)
            } else if !triedDiscovery {
                triedDiscovery = true
                await client.discoverAndConnect()
            } else {
                await client.connect(host: "127.0.0.1", port: 9330)
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
        }
    }
}
