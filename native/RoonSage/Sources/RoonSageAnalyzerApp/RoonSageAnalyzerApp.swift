import Foundation
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
            .task { model.autoEnrichIfEnabled() }   // trickle MusicBrainz genres in the background
            .task { model.loadCLAPIfNeeded() }   // start loading CLAP immediately — clapReady gates backfill
            .task { model.startServingIfNeeded() }
            // This app IS the server: connect to Roon on launch so the library
            // sync can run and the share server (5767) serves a populated DB.
            // The share server auto-starts via RoonClient init.
            .task { await connectRoon() }
            .task { await lastfmSyncLoop() }
            // The server keeps the AI artist radios fresh on Qobuz (every 3h).
            .task { client.startArtistRadioRefresh() }
            // The server builds the daily "Ontdekkingen" discovery feed.
            .task { client.startDiscoveryRefresh() }
            // …and, on the configured weekday, bundles the week's best pending
            // recommendations into a dated Qobuz digest playlist.
            .task { client.startDigestSchedule() }
            // Pull analyzed features (tags/year/embeddings) into library.db so they
            // reach the library without the manual Settings "Sync features" button.
            .task { client.startServerFeatureSync() }
        }
        .windowResizability(.contentSize)

        // Status item: the server runs headless most of the time, so surface its
        // Roon/analyse/serve state + reconnect & pause/resume in the menubar.
        MenuBarExtra("RoonSage Analyzer", systemImage: "waveform.path.ecg") {
            AnalyzerMenuBarContent()
                .environment(model)
                .environment(client)
        }
        .menuBarExtraStyle(.window)
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
    /// connected state: saved host → SOOD discovery → localhost (the server
    /// usually runs on the Core machine). A handshake that drops before
    /// authorization leaves RoonClient `.disconnected` without auto-reconnect,
    /// so we drive the retry here.
    ///
    /// Two resilience behaviours beyond the transport-level fixes:
    /// - `.connecting` is bounded: the transport now self-aborts a stalled
    ///   handshake (~18s), but as a final backstop we force a teardown if it
    ///   somehow lingers, so the UI never stays on "Verbinden met …" forever.
    /// - After repeated saved-host failures we fall through to SOOD discovery,
    ///   so a Core that moved to a new IP is rediscovered automatically.
    private func connectRoon() async {
        var savedHostFailures = 0
        var connectingSince: Date?
        while !Task.isCancelled {
            switch client.connectionState {
            case .connected, .awaitingAuthorization, .discovering:
                savedHostFailures = 0
                connectingSince = nil
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            case .connecting:
                let now = Date()
                let since = connectingSince ?? now
                connectingSince = since
                if now.timeIntervalSince(since) > 25 {
                    await client.disconnect()   // break a stuck handshake
                    connectingSince = nil
                } else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                continue
            default:
                connectingSince = nil
                break   // .disconnected / .failed → (re)try
            }
            if let host = client.savedHost, savedHostFailures < 3 {
                savedHostFailures += 1
                await client.connect(host: host, port: client.savedPort)
            } else {
                await client.discoverAndConnect()
                if case .failed = client.connectionState {
                    await client.connect(host: "127.0.0.1", port: 9330)
                }
                savedHostFailures = 0
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
        }
    }
}
