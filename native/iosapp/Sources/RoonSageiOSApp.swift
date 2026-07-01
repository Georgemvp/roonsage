import BackgroundTasks
import SwiftUI
import UIKit
import WidgetKit
import RoonSageCore
import RoonSageUI

/// iOS entry point. Reuses the shared RoonSageUI / RoonSageCore stack as-is; the
/// macOS-only chrome (menu-bar extra, Settings scene, in-app DMG updater) is
/// intentionally absent. On iOS, Settings is reachable as a tab and updates ship
/// through the App Store.
@main
@MainActor
struct RoonSageiOSApp: App {
    @State private var client: RoonClient
    @State private var bgTaskID: UIBackgroundTaskIdentifier = .invalid
    @Environment(\.scenePhase) private var scenePhase
    private let liveActivity = NowPlayingActivityController()
    private let nowPlayingCenter = NowPlayingCenter()

    init() {
        // This is a client: control Roon through the RoonSage server over HTTP,
        // never register a Roon extension on this device. Must run before connect.
        RoonClient.useServerMode()
        _client = State(initialValue: RoonClient.shared)
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.environment["RS_PREVIEW"] == "1" {
                NowPlayingPreviewHost()
                    .tint(.roonGold)
                    .environment(client)
            } else {
                mainScene
            }
            #else
            mainScene
            #endif
        }
        // Lifecycle-safe background refresh: BGTaskScheduler registration happens
        // before any scene connects when declared here (not in .onAppear).
        // BGTaskSchedulerPermittedIdentifiers must also list this ID in Info.plist.
        .backgroundTask(.appRefresh("com.roonsage.ios.refresh")) {
            await MainActor.run { scheduleNextBackgroundRefresh() }
            _ = await client.ensureConnected(timeout: 8)
            await MainActor.run { syncSystemSurfaces() }
        }
    }

    private var mainScene: some View {
        ContentView()
            .tint(.roonGold)
            .withHandoff()
            .environment(client)
            .onAppear {
                    nowPlayingCenter.configure(client: client)
                    // Prime the scheduler so the first refresh fires ~15 min later.
                    scheduleNextBackgroundRefresh()
                }
                // Mirror the selected zone's now-playing onto the lock screen /
                // Dynamic Island + MPNowPlayingInfoCenter (Control Center,
                // AirPods, CarPlay). Keyed on (nowPlaying, state) — not the
                // whole zone — so per-second seek updates don't spam ActivityKit.
                .onChange(of: client.selectedZone?.nowPlaying) { _, _ in
                    syncSystemSurfaces()
                }
                .onChange(of: client.selectedZone?.state) { _, _ in
                    syncSystemSurfaces()
                }
                .onChange(of: client.selectedZoneID) { _, _ in
                    syncSystemSurfaces()
                }
                // A sync that was interrupted by suspension resumes automatically
                // (album checkpoints — it skips what's already done) once the app
                // is active and the Core connection is back.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    // Reconnect immediately rather than waiting out the
                    // exponential backoff scheduled when iOS suspended us, so a
                    // play tap right after reopening hits a live socket instead
                    // of silently no-opping.
                    client.reconnectOnForeground()
                    if client.hasInterruptedSync, client.connectionState.isConnected {
                        client.startSync()
                    }
                    Task { await DiscoveryDigestNotifier.checkOnForeground(client: client) }
                }
                .onChange(of: client.connectionState.isConnected) { _, connected in
                    if connected, scenePhase == .active, client.hasInterruptedSync {
                        client.startSync()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Bij naar achtergrond gaan: laatste stand vastleggen
                    // zodat de home-screen widget actueel blijft.
                    if phase == .background { syncSystemSurfaces() }
                }
                .onChange(of: client.isSyncing) { _, syncing in
                    if syncing {
                        // Keep screen on so iOS doesn't suspend the app mid-sync.
                        UIApplication.shared.isIdleTimerDisabled = true
                        // Request background execution time (≈30 s) in case the
                        // user briefly backgrounds the app during a long sync.
                        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "LibrarySync") {
                            UIApplication.shared.endBackgroundTask(self.bgTaskID)
                            self.bgTaskID = .invalid
                        }
                    } else {
                        UIApplication.shared.isIdleTimerDisabled = false
                        if bgTaskID != .invalid {
                            UIApplication.shared.endBackgroundTask(bgTaskID)
                            bgTaskID = .invalid
                        }
                    }
                }
    }

    // MARK: - Background refresh (BGTaskScheduler)

    private func scheduleNextBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.roonsage.ios.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - System surfaces

    /// Eén plek die alle systeem-oppervlakken bijwerkt: de Live Activity,
    /// MPNowPlayingInfoCenter (Lock Screen/Control Center) en de App Group-
    /// snapshot waar de home-screen widget uit leest.
    private func syncSystemSurfaces() {
        let zone = client.selectedZone
        liveActivity.sync(zone: zone)
        nowPlayingCenter.sync(zone: zone)

        if let zone, let np = zone.nowPlaying,
           zone.state == .playing || zone.state == .paused {
            SharedNowPlaying.save(SharedNowPlaying(
                title: np.title,
                artist: np.artist,
                zoneName: zone.displayName,
                isPlaying: zone.state == .playing,
                updatedAt: Date()))
        } else {
            SharedNowPlaying.save(nil)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "ZoneControl")
    }
}
