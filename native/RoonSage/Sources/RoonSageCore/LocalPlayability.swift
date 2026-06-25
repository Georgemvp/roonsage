import AudioAnalysis
import Foundation

/// Pure helpers deciding which library tracks can play **on this device**.
///
/// A track is locally playable iff the analyser has an on-disk file for it —
/// equivalently, iff it has analysed audio features (every feature row was
/// produced from a walked file). Streaming-only library entries (e.g. Qobuz)
/// were never analysed from a file, so they have no features and can't be
/// streamed to the phone; the UI flags them and offers to drop them.
public enum LocalPlayability {
    /// Result of splitting a track list by local playability. (Not Equatable —
    /// TrackRecord isn't, and nothing compares partitions.)
    public struct Partition: Sendable {
        public let playable: [TrackRecord]
        public let blocked: [TrackRecord]
        public init(playable: [TrackRecord], blocked: [TrackRecord]) {
            self.playable = playable
            self.blocked = blocked
        }
    }

    /// The match key used for both the `/audio` lookup and feature joins —
    /// recomputed under the current `TrackIdentity` scheme so it agrees with the
    /// analyser's `/features` export (which re-keys the same way).
    public static func matchKey(for t: TrackRecord) -> String {
        let k = TrackIdentity.matchKey(artist: t.artist, album: t.album, title: t.title)
        return k.isEmpty ? (t.matchKey ?? "") : k
    }

    /// Split `tracks` into those playable on this device and those that aren't,
    /// given the set of feature-bearing match keys.
    public static func partition(_ tracks: [TrackRecord], playableKeys: Set<String>) -> Partition {
        var playable: [TrackRecord] = []
        var blocked: [TrackRecord] = []
        for t in tracks {
            let k = matchKey(for: t)
            if !k.isEmpty, playableKeys.contains(k) { playable.append(t) } else { blocked.append(t) }
        }
        return Partition(playable: playable, blocked: blocked)
    }
}

/// Summary of a local-playback attempt — drives the "X van Y speelbaar op deze
/// iPhone" filter notice in the UI.
public struct LocalPlaybackSummary: Sendable, Equatable {
    public var requested: Int
    public var playable: Int
    public var blocked: Int
    /// A few blocked track titles, for a human-readable hint.
    public var blockedExamples: [String]

    public init(requested: Int, playable: Int, blocked: Int, blockedExamples: [String]) {
        self.requested = requested
        self.playable = playable
        self.blocked = blocked
        self.blockedExamples = blockedExamples
    }

    public var allPlayable: Bool { blocked == 0 }
    public var nonePlayable: Bool { playable == 0 }
}
