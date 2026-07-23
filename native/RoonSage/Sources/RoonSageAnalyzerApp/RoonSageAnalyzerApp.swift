import Foundation
import RoonSageCore
import RoonSageUI
import SwiftUI

@MainActor
@main
struct RoonSageAnalyzerApp: App {
    @State private var model: AnalyzerModel
    @State private var updater: AnalyzerUpdater
    @State private var client: RoonClient

    init() {
        // Register as the distinct "RoonSage Server" Roon extension before the
        // shared client is touched, so we don't clash with the client apps.
        RoonClient.useServerIdentity()
        let client = RoonClient.shared
        let model = AnalyzerModel()
        let updater = AnalyzerUpdater()
        _client = State(initialValue: client)
        _model = State(initialValue: model)
        _updater = State(initialValue: updater)

        // Device-approval rollout: switch on token enforcement once, so from now
        // on only clients approved under "Apparaten" are served (unknown tokens
        // land in the pending queue instead of being silently accepted). One-shot
        // so the user can still turn it back off in Settings.
        let d = UserDefaults.standard
        if !d.bool(forKey: "device_approval_migrated") {
            LibraryShareServer.enforceToken = true
            d.set(true, forKey: "device_approval_migrated")
        }

        // Start ALL server background work here, NOT from a SwiftUI `.task`. This
        // app is a headless server; when the mini's display is asleep its Window
        // scene never activates, so Window `.task` modifiers silently never fire —
        // which used to leave the server unable to connect to Roon, serve :5766,
        // load CLAP, or run its analysis/enrichment jobs. init() always runs.
        // (RoonClient's own loops — Roon connect, Last.fm, the Qobuz/discovery/
        // lyrics schedules — are started from RoonClient.init(); the AnalyzerModel
        // jobs, which need `model`, are started here.) All are idempotent.
        Task { await updater.checkOnLaunch() }
        model.autoStartIfEnabled()
        model.autoEnrichIfEnabled()          // trickle MusicBrainz genres
        model.autoPopularityIfEnabled()      // trickle Deezer popularity
        model.autoLoudnessIfEnabled()        // backfill F3 loudness (disk-gentle)
        model.autoPreviewIfEnabled()         // embed file-less (Qobuz) tracks
        model.autoDeezerGenreIfEnabled()     // backfill Deezer genres
        model.autoArousalRefreshIfNeeded()   // one-time perceptual-energy axis
        model.loadCLAPIfNeeded()             // start loading CLAP immediately
        model.startServingIfNeeded()         // the :5766 analyzer/audio server
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
            // NB: all server background work (Roon connect, Last.fm, :5766 serve,
            // CLAP, analysis, the Qobuz/discovery/lyrics schedules) is started from
            // init() — NOT a `.task` here — because this Window's `.task` modifiers
            // never fire when the headless mini's display is asleep. See init().
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

}
