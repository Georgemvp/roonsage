import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Live Activity contract shared by the app (which starts/updates the activity)
/// and the widget extension (which renders it on the lock screen / Dynamic
/// Island). Keep this file dependency-free — it is compiled into both targets.
struct NowPlayingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String?
        var album: String?
        var isPlaying: Bool
        /// Wall-clock moment the current track started (now − seek position).
        /// Lets the lock screen run its own elapsed timer without per-second
        /// activity updates from the app.
        var startedAt: Date?
        /// Track length in seconds (0 = unknown).
        var length: Int
    }

    /// The Roon zone this activity follows (fixed for the activity's lifetime).
    var zoneName: String
}
#endif
