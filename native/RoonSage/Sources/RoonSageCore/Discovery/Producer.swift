import Foundation

// MARK: - Discovery producers
//
// A producer emits raw candidate artists/albums from one source (Last.fm similar
// artists, MusicBrainz relationships, an LLM, …). The pipeline collects every
// producer's candidates, groups them by `DiscoveryKey.dedupKey` (so cross-source
// agreement becomes the `consensus` score), then resolves/scores/filters/stores.

/// One raw candidate before resolution. Mutable so the resolver can attach the
/// canonical name, MBIDs and Qobuz id in place.
public struct Candidate: Sendable {
    public var kind: RecommendationKind
    public var artist: String
    public var album: String?
    public var year: Int?
    public var genres: [String]
    public var similarity: Double?      // producer-local 0…1
    public var aiConfidence: Double?    // AI producer only
    public var sourceURL: String?
    public var producer: String         // stable id
    public var artistMbid: String?
    public var releaseGroupMbid: String?
    /// Set by gap-fill (1.0 = fills a real gap) — feeds the album score modifier.
    public var gapPriority: Double?

    public init(kind: RecommendationKind, artist: String, album: String? = nil, year: Int? = nil,
                genres: [String] = [], similarity: Double? = nil, aiConfidence: Double? = nil,
                sourceURL: String? = nil, producer: String, artistMbid: String? = nil,
                releaseGroupMbid: String? = nil, gapPriority: Double? = nil) {
        self.kind = kind; self.artist = artist; self.album = album; self.year = year
        self.genres = genres; self.similarity = similarity; self.aiConfidence = aiConfidence
        self.sourceURL = sourceURL; self.producer = producer; self.artistMbid = artistMbid
        self.releaseGroupMbid = releaseGroupMbid; self.gapPriority = gapPriority
    }
}

/// What the producers get to work from — the taste profile assembled by the
/// pipeline's Analyze step (top/liked artists, the library's own artists+genres
/// for filtering, the watchlist for Release-Radar, and the CLAP taste centroid).
public struct DiscoverySeeds: Sendable {
    public var topArtists: [String]         // most-played, display case
    public var likedArtists: [String]       // thumbed-up
    public var dislikedArtists: [String]
    public var libraryArtists: Set<String>  // lowercased — for in-library filtering
    public var libraryGenres: Set<String>   // lowercased — for genreOverlap scoring
    /// Owned albums as lowercased "artist|album" keys — gap-fill diffs against this.
    public var libraryAlbumKeys: Set<String>
    public var watchlist: [WatchlistArtist]
    public var tasteVector: [Float]?

    public init(topArtists: [String] = [], likedArtists: [String] = [], dislikedArtists: [String] = [],
                libraryArtists: Set<String> = [], libraryGenres: Set<String> = [],
                libraryAlbumKeys: Set<String> = [], watchlist: [WatchlistArtist] = [], tasteVector: [Float]? = nil) {
        self.topArtists = topArtists; self.likedArtists = likedArtists
        self.dislikedArtists = dislikedArtists; self.libraryArtists = libraryArtists
        self.libraryGenres = libraryGenres; self.libraryAlbumKeys = libraryAlbumKeys
        self.watchlist = watchlist; self.tasteVector = tasteVector
    }
}

/// A watchlisted artist (mirrors the `artist_watchlist` row).
public struct WatchlistArtist: Codable, Sendable, Hashable {
    public var artist: String          // lowercased key
    public var artistMbid: String?
    public var displayName: String
    public var lastSeenReleaseGroup: String?
    public init(artist: String, artistMbid: String? = nil, displayName: String, lastSeenReleaseGroup: String? = nil) {
        self.artist = artist; self.artistMbid = artistMbid
        self.displayName = displayName; self.lastSeenReleaseGroup = lastSeenReleaseGroup
    }
}

/// Shared clients + configuration handed to every producer. Optional members are
/// nil when the corresponding service isn't configured; a producer whose inputs
/// are missing returns `isEnabled == false` and is skipped.
public struct ProducerContext: Sendable {
    public var lastfm: LastfmCredentials?
    public var listenBrainz: ListenBrainzCredentials?
    public var musicBrainz: MusicBrainzDiscoveryClient
    /// `LLMConfigStore.load()` always returns something (defaults to local Ollama),
    /// so there's no "unconfigured" state distinct from "configured but
    /// unreachable" — the AI producer just attempts the call and returns no
    /// candidates on failure, like every other network producer.
    public var llmConfig: LLMConfig
    /// Max candidates a single producer should emit per run (keeps MB resolve
    /// within its rate budget).
    public var perProducerLimit: Int
    /// F11 dial (0 = veilig … 1 = avontuurlijk). Producers that expose a
    /// popularity/similarity-depth mode (currently `ListenBrainzRadioProducer`'s
    /// easy/medium/hard) map this onto that mode; others ignore it. The Score
    /// stage reads the same value via `ScoringWeights.tuned(adventurousness:)`.
    public var adventurousness: Double
    /// F12a mood-seeded run: the raw CLAP mood key (e.g. "sad", "aggressive") the
    /// user asked for, so a producer that can reason about vibe (currently just
    /// `AIPicksProducer`) can lean into it. Most producers ignore this — the mood
    /// bias mainly happens upstream, in which SEED artists `DiscoverySeeds` carries.
    public var mood: String?
    /// F7: Discogs personal access token — gates `DiscogsLabelsProducer`.
    public var discogsToken: String?
    /// F2: Qobuz login — gates `QobuzCatalogProducer`, which discovers not-owned
    /// albums straight from the Qobuz catalogue (no MusicBrainz round-trip).
    public var qobuz: QobuzCredentials?
    /// Path to the distilled MusicMoveArr sidecar (metadata.db) — gates
    /// `DatasetProducer`. nil / missing file degrades to "one fewer producer".
    public var datasetSidecarPath: String?

    public init(lastfm: LastfmCredentials? = nil, listenBrainz: ListenBrainzCredentials? = nil,
                musicBrainz: MusicBrainzDiscoveryClient, llmConfig: LLMConfig = LLMConfig(),
                perProducerLimit: Int = 40, adventurousness: Double = 0.35, mood: String? = nil,
                discogsToken: String? = nil,
                qobuz: QobuzCredentials? = nil, datasetSidecarPath: String? = nil) {
        self.lastfm = lastfm; self.listenBrainz = listenBrainz; self.musicBrainz = musicBrainz
        self.llmConfig = llmConfig; self.perProducerLimit = perProducerLimit
        self.adventurousness = adventurousness
        self.mood = mood; self.discogsToken = discogsToken; self.qobuz = qobuz
        self.datasetSidecarPath = datasetSidecarPath
    }
}

/// Qobuz login for catalogue discovery (email + password, like the existing
/// playlist-save path). Passed per producer via `ProducerContext`.
public struct QobuzCredentials: Sendable {
    public var email: String
    public var password: String
    public init(email: String, password: String) { self.email = email; self.password = password }
}

/// Last.fm read credentials (api key + username), passed per call like the
/// existing `LastfmClient` read methods.
public struct LastfmCredentials: Sendable {
    public var apiKey: String
    public var username: String
    public init(apiKey: String, username: String) { self.apiKey = apiKey; self.username = username }
}

/// ListenBrainz credentials (username + optional token).
public struct ListenBrainzCredentials: Sendable {
    public var username: String
    public var token: String?
    public init(username: String, token: String? = nil) { self.username = username; self.token = token }
}

/// A discovery producer. `id` is the stable name recorded in `sources_json`;
/// `isEnabled` gates producers whose service/credentials aren't configured.
public protocol DiscoveryProducer: Sendable {
    var id: String { get }
    func isEnabled(_ context: ProducerContext) -> Bool
    func discover(seeds: DiscoverySeeds, context: ProducerContext) async -> [Candidate]
}
