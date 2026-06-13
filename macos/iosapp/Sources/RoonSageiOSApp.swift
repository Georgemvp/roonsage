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
    @State private var client = RoonClient.shared
    @State private var bgTaskID: UIBackgroundTaskIdentifier = .invalid
    @Environment(\.scenePhase) private var scenePhase
    private let liveActivity = NowPlayingActivityController()
    private let nowPlayingCenter = NowPlayingCenter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(client)
                .tint(.roonGold)
                .withHandoff()
                .onAppear {
                    nowPlayingCenter.configure(client: client)
                    BGTaskScheduler.shared.register(
                        forTaskWithIdentifier: "com.roonsage.ios.refresh",
                        using: nil
                    ) { task in
                        self.handleBackgroundRefresh(task: task as! BGAppRefreshTask)
                    }
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
                    if phase == .active, client.hasInterruptedSync,
                       client.connectionState.isConnected {
                        client.startSync()
                    }
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
    }

    // MARK: - Background refresh (BGTaskScheduler)

    /// Refresh zone state + widget data in the background (~15 min interval).
    /// iOS calls this when the app is suspended; we reconnect briefly, sync
    /// surfaces, then schedule the next execution.
    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        scheduleNextBackgroundRefresh()
        let workTask = Task {
            _ = await client.ensureConnected(timeout: 8)
            await MainActor.run { syncSystemSurfaces() }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            workTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }

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
