import Foundation

// MARK: - Discovery filter (pure — unit-tested in DiscoveryFilterTests)
//
// The drop stage, adapted from digarr's filter.ts. Every rule is pure so the
// whole table tests without a DB. Order matches digarr: in-library → already
// listened → permanently blocked → within reject cooldown → below score threshold.

public enum DiscoveryReject: String, Sendable {
    case inLibrary, alreadyListened, blocked, cooldown, belowThreshold
}

/// A remembered rejection (from `discovery_rejections`).
public struct RejectionInfo: Sendable {
    public var rejectedAt: Date?
    public var permanent: Bool
    public init(rejectedAt: Date?, permanent: Bool) { self.rejectedAt = rejectedAt; self.permanent = permanent }
}

/// Everything the filter consults, assembled once per run (all lowercased).
public struct DiscoveryFilterContext: Sendable {
    public var libraryArtists: Set<String>       // artists you already own
    public var libraryAlbumKeys: Set<String>     // "artist|album" you already own
    public var listenedArtists: Set<String>      // artists in listening_history
    public var rejections: [String: RejectionInfo]  // dedupKey → rejection
    public var cooldownDays: Int
    public var scoreThreshold: Double
    public var now: Date

    public init(libraryArtists: Set<String> = [], libraryAlbumKeys: Set<String> = [],
                listenedArtists: Set<String> = [], rejections: [String: RejectionInfo] = [:],
                cooldownDays: Int = 60, scoreThreshold: Double = 0.35, now: Date = Date()) {
        self.libraryArtists = libraryArtists; self.libraryAlbumKeys = libraryAlbumKeys
        self.listenedArtists = listenedArtists; self.rejections = rejections
        self.cooldownDays = cooldownDays; self.scoreThreshold = scoreThreshold; self.now = now
    }

    static func albumKey(artist: String, album: String) -> String {
        "\(artist.lowercased().trimmingCharacters(in: .whitespaces))|\(album.lowercased().trimmingCharacters(in: .whitespaces))"
    }
}

public enum DiscoveryFilter {

    /// Why a candidate is dropped, or nil to keep it. Returning the reason (rather
    /// than a bare Bool) makes the rule table trivially testable and lets a future
    /// analytics view report *why* the funnel narrowed.
    public static func rejectReason(kind: RecommendationKind, artist: String, album: String?,
                                    dedupKey: String, score: Double,
                                    context c: DiscoveryFilterContext) -> DiscoveryReject? {
        let a = artist.lowercased().trimmingCharacters(in: .whitespaces)

        // 1. Already in the library.
        switch kind {
        case .artist:
            if c.libraryArtists.contains(a) { return .inLibrary }
        case .album:
            // An album is "owned" only if we have that exact album — a gap-fill /
            // release-radar album by an owned artist must survive.
            if let alb = album, c.libraryAlbumKeys.contains(DiscoveryFilterContext.albumKey(artist: a, album: alb)) {
                return .inLibrary
            }
        }

        // 2. An artist you already actively listen to isn't a discovery. Only drops
        //    the artist-kind — an unowned album by a listened artist is exactly what
        //    gap-fill / release-radar are for.
        if kind == .artist, c.listenedArtists.contains(a) { return .alreadyListened }

        // 3. Permanent block — independent of cooldown, always drops.
        if let r = c.rejections[dedupKey], r.permanent { return .blocked }

        // 4. Rejected within the cooldown window.
        if let r = c.rejections[dedupKey], !r.permanent, let at = r.rejectedAt {
            let elapsed = c.now.timeIntervalSince(at)
            if elapsed < Double(c.cooldownDays) * 24 * 60 * 60 { return .cooldown }
        }

        // 5. Below the score threshold.
        if score < c.scoreThreshold { return .belowThreshold }

        return nil
    }

    public static func keep(kind: RecommendationKind, artist: String, album: String?,
                            dedupKey: String, score: Double, context: DiscoveryFilterContext) -> Bool {
        rejectReason(kind: kind, artist: artist, album: album, dedupKey: dedupKey, score: score, context: context) == nil
    }
}
