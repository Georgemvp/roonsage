import Foundation

public struct DeezerGenreProgress: Sendable {
    public var enriched: Int    // tracks that got ≥1 Deezer genre
    public var checked: Int     // tracks looked up (incl. fruitless)
    public var albums: Int      // albums processed this run
    public var total: Int
}

/// Backfills owned tracks' genres from Deezer's album-detail endpoint — a
/// second signal alongside MusicBrainz (`GenreEnricher`), whose per-release
/// genre coverage is sparse. One track search per album (to resolve a Deezer
/// album id, since Deezer's search only takes artist+track) followed by one
/// album-detail lookup; every track on the album is stamped in one write.
/// Memoized per album id within a run (the group-by-album query already
/// prevents repeats, but a defensive cache costs nothing). Resumable via
/// `deezer_genre_checked_at`, like the other enrichers.
public final class DeezerGenreEnricher {
    private let store: FeatureStore
    private let client: DeezerClient
    private let albumBatch: Int
    private var cancelled = false
    private var genreCache: [Int: [String]?] = [:]

    public init(store: FeatureStore, client: DeezerClient = .shared, albumBatch: Int = 50) {
        self.store = store
        self.client = client
        self.albumBatch = max(1, albumBatch)
    }

    public func cancel() { cancelled = true }

    public func run(onProgress: @escaping @Sendable (DeezerGenreProgress) -> Void) async {
        let total = store.count()
        guard total > 0 else { return }
        var albumsDone = 0

        while !cancelled {
            let groups = store.albumsNeedingDeezerGenre(limit: albumBatch)
            if groups.isEmpty { break }
            for g in groups {
                if cancelled { break }
                let genres = await genres(artist: g.artist, sampleTitle: g.sampleTitle)
                try? store.setDeezerGenres(matchKeys: g.matchKeys, genres: genres ?? [], checkedAt: Self.now())
                albumsDone += 1
                onProgress(DeezerGenreProgress(enriched: store.deezerGenreEnrichedCount(),
                                               checked: store.deezerGenreCheckedCount(),
                                               albums: albumsDone, total: total))
            }
        }
    }

    private func genres(artist: String, sampleTitle: String) async -> [String]? {
        guard let albumID = await client.trackAlbumID(artist: artist, title: sampleTitle) else { return nil }
        if let cached = genreCache[albumID] { return cached }
        let genres = await client.albumGenres(albumID: albumID)
        genreCache[albumID] = genres
        return genres
    }

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}
