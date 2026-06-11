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
    @State private var client = RoonClient()
    @State private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(client)
                .tint(.roonGold)
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
