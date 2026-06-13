import Foundation
import RoonSageCore
import SwiftUI

/// Handoff / NSUserActivity support.
/// Advertises the selected zone so the macOS companion (or another device)
/// can resume playback in the same zone via Continuity Handoff.
enum HandoffCoordinator {
    static let activityType = "com.roonsage.zone"
}

// MARK: - View modifier

struct HandoffModifier: ViewModifier {
    @Environment(RoonClient.self) private var client

    func body(content: Content) -> some View {
        content
            // Broadcast the selected zone as a Handoff activity.
            .userActivity(HandoffCoordinator.activityType, isActive: client.selectedZone != nil) { activity in
                guard let zone = client.selectedZone else { return }
                activity.title = "Afspelen in \(zone.displayName)"
                activity.userInfo = ["zoneID": zone.id, "zoneName": zone.displayName]
                activity.isEligibleForHandoff = true
            }
            // Receive a Handoff from another device → select the zone.
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
