import SwiftUI
import UIKit
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
                .onAppear { nowPlayingCenter.configure(client: client) }
                // Mirror the selected zone's now-playing onto the lock screen /
                // Dynamic Island + MPNowPlayingInfoCenter (Control Center,
                // AirPods, CarPlay). Keyed on (nowPlaying, state) — not the
                // whole zone — so per-second seek updates don't spam ActivityKit.
                .onChange(of: client.selectedZone?.nowPlaying) { _, _ in
                    liveActivity.sync(zone: client.selectedZone)
                    nowPlayingCenter.sync(zone: client.selectedZone)
                }
                .onChange(of: client.selectedZone?.state) { _, _ in
                    liveActivity.sync(zone: client.selectedZone)
                    nowPlayingCenter.sync(zone: client.selectedZone)
                }
                .onChange(of: client.selectedZoneID) { _, _ in
                    liveActivity.sync(zone: client.selectedZone)
                    nowPlayingCenter.sync(zone: client.selectedZone)
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
}
