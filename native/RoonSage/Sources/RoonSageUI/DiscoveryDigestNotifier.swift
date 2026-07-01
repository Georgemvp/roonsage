import Foundation
import RoonSageCore
import UserNotifications

// MARK: - Weekly digest local notification (F12b)
//
// There is no push infrastructure in RoonSage (self-hosted, no APNs) — this is
// deliberately a LOCAL notification, fired by whichever device happens to be
// foregrounded and notices a digest it hasn't acknowledged yet. Each device
// tracks its own "last seen week" (UserDefaults is per-device), so a Mac and an
// iPhone both notify independently rather than racing over a shared flag.

@MainActor
public enum DiscoveryDigestNotifier {
    private static let lastSeenWeekKey = "discovery_last_seen_digest_week"
    private static let lastCheckKey = "discovery_last_digest_check"
    /// Throttle so rapid re-foregrounding (switching apps back and forth) doesn't
    /// hit the server every time — an hour comfortably beats any real digest
    /// cadence (weekly).
    private static let checkInterval: TimeInterval = 3600

    /// Call on app launch/foreground. Fetches the server's digest status; if it
    /// names a week this DEVICE hasn't acknowledged, requests notification
    /// permission (first time only) and fires a local "N new discoveries" alert.
    public static func checkOnForeground(client: RoonClient) async {
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard now - last > checkInterval else { return }
        UserDefaults.standard.set(now, forKey: lastCheckKey)

        let status = await client.discoveryDigestStatus()
        guard let week = status.week, status.count > 0 else { return }
        guard week != UserDefaults.standard.string(forKey: lastSeenWeekKey) else { return }
        UserDefaults.standard.set(week, forKey: lastSeenWeekKey)

        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .denied:
            return   // respect a prior no — don't re-prompt every week
        case .notDetermined:
            guard let granted = try? await center.requestAuthorization(options: [.alert, .sound]), granted
            else { return }
        default:
            break   // authorized / provisional / ephemeral
        }

        let content = UNMutableNotificationContent()
        content.title = "Ontdekkingen"
        content.body = status.count == 1
            ? "1 nieuwe ontdekking deze week."
            : "\(status.count) nieuwe ontdekkingen deze week."
        content.sound = .default
        // Stable per-week identifier: re-delivering the same week's notification
        // (e.g. a retry after a transient failure) replaces rather than duplicates.
        let request = UNNotificationRequest(identifier: "discovery-digest-\(week)", content: content, trigger: nil)
        try? await center.add(request)
    }
}
