import SwiftUI
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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(client)
                .tint(.roonGold)
        }
    }
}
