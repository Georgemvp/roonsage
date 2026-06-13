import Foundation
import RoonSageCore
import SwiftUI

/// Handoff / NSUserActivity support.
/// Publishes the selected zone as a `com.roonsage.zone` activity so the
/// macOS companion app (or another iOS device) can resume playback in the
/// same zone via Handoff or Spotlight.
enum HandoffCoordinator {
    static let activityType = "com.roonsage.zone"

    /// Call whenever the selected zone changes to advertise it to other devices.
    @MainActor
    static func advertise(zone: RoonZone?) {
        guard let zone else {
            // Invalidate any current activity.
            NSUserActivity.current?.invalidate()
            return
        }
        let activity = NSUserActivity(activityType: activityType)
        activity.title = "Afspelen in \(zone.displayName)"
        activity.userInfo = ["zoneID": zone.id, "zoneName": zone.displayName]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.becomeCurrent()
    }
}

// MARK: - View modifier

/// Apply to ContentView so zone changes broadcast a Handoff activity.
struct HandoffModifier: ViewModifier {
    @Environment(RoonClient.self) private var client

    func body(content: Content) -> some View {
        content
            .onChange(of: client.selectedZoneID) { _, _ in
                HandoffCoordinator.advertise(zone: client.selectedZone)
            }
            .onContinueUserActivity(HandoffCoordinator.activityType) { activity in
                guard let zoneID = activity.userInfo?["zoneID"] as? String else { return }
                client.selectZone(zoneID)
            }
    }
}

extension View {
    func withHandoff() -> some View {
        modifier(HandoffModifier())
    }
}
