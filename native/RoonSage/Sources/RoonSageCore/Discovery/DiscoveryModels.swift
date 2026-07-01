import Foundation

// MARK: - Discovery engine — shared models
//
// The outward-facing recommendation engine (a native adaptation of digarr's
// 7-stage pipeline: Collect → Discover → Resolve → Score → Filter → Store).
// Unlike the inward-facing `DiscoveryView` (which surfaces what you already own),
// this finds artists/albums you DON'T have yet and resolves them to Qobuz so
// they're actually playable/saveable. These value types are the wire/DB contract;
// the pipeline stages live in Producer/DiscoveryScoring/DiscoveryFilter/
// DiscoveryResolver/DiscoveryPipeline.

/// Recommendation granularity. digarr's headline feature is album-level.
public enum RecommendationKind: String, Codable, Sendable, CaseIterable {
    case artist, album
}

/// One producer's contribution to a recommendation — kept in `sources_json` so
/// the feed can show "3 sources agreed" and the score is explainable.
public struct SourceRef: Codable, Sendable, Hashable {
    public var producer: String        // stable id, e.g. "similar-artist-web"
    public var similarity: Double?     // producer-local 0…1
    public var aiConfidence: Double?   // AI producer only
    public var url: String?
    public init(producer: String, similarity: Double? = nil, aiConfidence: Double? = nil, url: String? = nil) {
        self.producer = producer; self.similarity = similarity
        self.aiConfidence = aiConfidence; self.url = url
    }
}

/// The composite score broken into its parts (persisted in `score_json`) so the
/// UI / a future analytics view can show WHY something scored as it did.
public struct ScoreComponents: Codable, Sendable {
    public var consensus: Double = 0
    public var similarity: Double = 0
    public var genreOverlap: Double = 0
    public var aiConfidence: Double = 0
    public var feedbackBoost: Double = 0
    public var popularity: Double = 0
    public var albumModifier: Double = 0
    public init() {}
}

/// The weighted-composite weights (digarr's `default` preset, verbatim). They sum
/// to 1.0; `popularity` is reserved at 0 until a streaming producer supplies it.
public struct ScoringWeights: Sendable {
    public var consensus: Double = 0.30
    public var similarity: Double = 0.25
    public var genreOverlap: Double = 0.20
    public var aiConfidence: Double = 0.15
    public var feedbackBoost: Double = 0.10
    public var popularity: Double = 0.0
    public init() {}
    public static let `default` = ScoringWeights()
}

/// One recommendation as served to clients (`GET /discovery/recommendations`) and
/// rendered in the feed. All new fields are `Optional`-tolerant so a newer client
/// tolerates an older server and vice-versa.
public struct RecommendationItemDTO: Codable, Sendable, Identifiable {
    public var id: Int64
    public var kind: RecommendationKind
    public var artist: String
    public var artistMbid: String?
    public var album: String?
    public var releaseGroupMbid: String?
    public var year: Int?
    public var qobuzAlbumID: String?
    public var imageURL: String?
    public var score: Double
    public var components: ScoreComponents?
    public var sources: [SourceRef]
    public var genres: [String]
    public var explanation: String?
    public var status: String          // pending|accepted|rejected
    public var createdAt: String

    public init(id: Int64, kind: RecommendationKind, artist: String, artistMbid: String? = nil,
                album: String? = nil, releaseGroupMbid: String? = nil, year: Int? = nil,
                qobuzAlbumID: String? = nil, imageURL: String? = nil, score: Double = 0,
                components: ScoreComponents? = nil, sources: [SourceRef] = [], genres: [String] = [],
                explanation: String? = nil, status: String = "pending", createdAt: String) {
        self.id = id; self.kind = kind; self.artist = artist; self.artistMbid = artistMbid
        self.album = album; self.releaseGroupMbid = releaseGroupMbid; self.year = year
        self.qobuzAlbumID = qobuzAlbumID; self.imageURL = imageURL; self.score = score
        self.components = components; self.sources = sources; self.genres = genres
        self.explanation = explanation; self.status = status; self.createdAt = createdAt
    }

    /// Whether Accept can actually act on this (must resolve to a Qobuz album).
    public var isActionable: Bool { kind == .artist || (qobuzAlbumID?.isEmpty == false) }
}

/// Status of the newest batch, for `GET /discovery/run-status`.
public struct DiscoveryRunStatus: Codable, Sendable {
    public var status: String          // running|complete|failed|idle
    public var itemCount: Int
    public var createdAt: String?
    public init(status: String, itemCount: Int, createdAt: String?) {
        self.status = status; self.itemCount = itemCount; self.createdAt = createdAt
    }
}

// MARK: - Dedup key

public enum DiscoveryKey {
    /// The stable identity used for grouping producers, DB dedup, and the reject
    /// memory. Album keys prefer the release-group MBID; artist keys prefer the
    /// artist MBID; both fall back to normalized names so a candidate with no MBID
    /// yet still dedupes consistently.
    public static func dedupKey(kind: RecommendationKind, artist: String, album: String?,
                                artistMbid: String?, releaseGroupMbid: String?) -> String {
        let a = artist.lowercased().trimmingCharacters(in: .whitespaces)
        switch kind {
        case .album:
            // A release-group MBID is canonical on its own — different spellings of
            // the same album collapse. Fall back to artist+title when unresolved.
            if let rg = releaseGroupMbid, !rg.isEmpty { return "album|\(rg)" }
            let alb = (album ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            return "album|\(a)|\(alb)"
        case .artist:
            if let mb = artistMbid, !mb.isEmpty { return "artist|\(mb)" }
            return "artist|\(a)"
        }
    }
}
