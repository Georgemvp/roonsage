import Foundation
import GRDB

// MARK: - Custom radio config (user-composed sonic radio)
//
// A `RadioConfig` is a NAMED bundle of seed facets the user assembles themselves:
// any mix of artists, tracks, genres, moods and activities (optionally decades).
// Unlike the engine's auto-generated stations (`RadioCategory`), these are
// first-class, editable entities that live on the server-of-record so every
// client sees the same set — and that the always-on analyzer materialises into a
// stable Qobuz playlist. The same definition also plays as an endless station.
//
// Facet roles (see RoonClient+CustomRadio):
//   • artists / tracks   — SEED-ONLY (proximity is the definition; no gate).
//   • genres / moods / activities / decades — SEED **and** a measured GATE that
//     is AND-ed together (with relaxation) so the station stays true to its name.
//
// Array facets are stored as JSON-text columns (GRDB encodes non-scalar Codable
// properties as JSON automatically); the same struct doubles as the wire DTO the
// client POSTs/GETs over `/radio-configs`, so client and server share one shape.

public struct RadioConfig: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "radio_configs"

    public var id: String                 // uuid; the radio id is "custom:<id>"
    public var name: String
    public var enabled: Bool
    public var syncToQobuz: Bool
    public var artists: [String]          // artist display names (seed-only)
    public var trackKeys: [String]        // match_keys (seed-only)
    public var genres: [String]           // lowercased genre keys (seed + gate)
    public var moods: [String]            // CLAP mood keys (seed + gate)
    public var activities: [String]       // activity profile keys (seed + gate)
    public var decades: [Int]             // release decades, e.g. 1980 (seed + gate)
    public var adventurousness: Double    // 0…1, mirrors RoonClient.radioAdventurousness
    public var targetCount: Int           // playlist / first-batch size
    public var qobuzPlaylistID: String?   // resolved once mirrored (rename-in-place)
    public var updatedAt: String          // ISO-8601, bumped on every save

    /// Stable radio id used by playback + the gate lookup ("custom:<uuid>").
    public var radioID: String { "custom:\(id)" }

    /// True when at least one facet is set — an empty config can't seed anything.
    public var hasFacets: Bool {
        !artists.isEmpty || !trackKeys.isEmpty || !genres.isEmpty
            || !moods.isEmpty || !activities.isEmpty || !decades.isEmpty
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        enabled: Bool = true,
        syncToQobuz: Bool = true,
        artists: [String] = [],
        trackKeys: [String] = [],
        genres: [String] = [],
        moods: [String] = [],
        activities: [String] = [],
        decades: [Int] = [],
        adventurousness: Double = RoonClient.defaultAdventurousness,
        targetCount: Int = 25,
        qobuzPlaylistID: String? = nil,
        updatedAt: String = ""
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.syncToQobuz = syncToQobuz
        self.artists = artists
        self.trackKeys = trackKeys
        self.genres = genres
        self.moods = moods
        self.activities = activities
        self.decades = decades
        self.adventurousness = adventurousness
        self.targetCount = targetCount
        self.qobuzPlaylistID = qobuzPlaylistID
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, artists, genres, moods, activities, decades
        case syncToQobuz     = "sync_to_qobuz"
        case trackKeys       = "track_keys"
        case adventurousness
        case targetCount     = "target_count"
        case qobuzPlaylistID = "qobuz_playlist_id"
        case updatedAt       = "updated_at"
    }
}
