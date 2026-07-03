import Foundation
import ActivityKit
import RoonSageCore

/// Drives the now-playing Live Activity from the selected zone's state.
///
/// Lifecycle: starts an activity when the zone begins playing, updates it on
/// track change, and ends it as soon as playback pauses/stops or the zone
/// goes away — the notification is only visible while actually playing.
/// Updates are driven by `(nowPlaying, state)` changes only — the elapsed
/// timer on the lock screen ticks system-side via `startedAt`, so we never
/// push per-second updates. Note: without push tokens the activity can go
/// stale once iOS suspends the app for a long time; v1 accepts that.
@MainActor
final class NowPlayingActivityController {
    private var activity: Activity<NowPlayingAttributes>?
    private var lastZoneID: String?

    /// Reconcile the Live Activity with the zone's current state.
    func sync(zone: Zone?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Zone switched → the activity follows the new zone from scratch.
        if zone?.id != lastZoneID {
            endActivity()
            lastZoneID = zone?.id
        }

        // Only show the Live Activity while actually playing — a paused or
        // stopped zone ends it (re-created when playback resumes).
        guard let zone, let np = zone.nowPlaying, zone.state == .playing else {
            endActivity()
            return
        }

        let state = NowPlayingAttributes.ContentState(
            title: np.title,
            artist: np.artist,
            album: np.album,
            isPlaying: zone.state == .playing,
            startedAt: zone.seekPosition.map { Date().addingTimeInterval(-$0) },
            length: np.length ?? 0
        )

        // Without push tokens the activity can't update while the app is
        // suspended; mark it stale once the track should have ended so iOS
        // dims it instead of showing a frozen wrong track indefinitely.
        let remaining = max(60, Double(np.length ?? 600) - (zone.seekPosition ?? 0) + 30)
        let stale = Date().addingTimeInterval(remaining)

        if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: stale)) }
        } else {
            do {
                activity = try Activity.request(
                    attributes: NowPlayingAttributes(zoneName: zone.displayName),
                    content: ActivityContent(state: state, staleDate: stale)
                )
            } catch {
                // Denied/limited by the system (e.g. too many activities) — fine.
            }
        }
    }

    func endActivity() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
