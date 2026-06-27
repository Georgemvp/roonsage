import Foundation

public struct EnrichProgress: Sendable {
    public var enriched: Int    // tracks that got ≥1 MusicBrainz genre
    public var checked: Int     // tracks looked up (incl. fruitless)
    public var albums: Int      // albums processed this run
    public var total: Int
}

/// Enriches analyzed tracks with MusicBrainz genres and builds the genre
/// hierarchy, all analyzer-side. Album-level matching (one release lookup per
/// album), recording-level fallback for album-less tracks, then a taxonomy pass
/// that resolves parent genres for the vocabulary the library actually uses.
///
/// Resumable: only un-enriched rows (`mb_checked_at IS NULL`) are queried, so an
/// interrupted run continues where it left off. Rate limiting lives in
/// `MusicBrainzClient` (~1 req/s), so this worker can fire requests back-to-back.
public final class GenreEnricher {
    private let store: FeatureStore
    private let client: MusicBrainzClient
    private let albumBatch: Int
    private var cancelled = false

    public init(store: FeatureStore, client: MusicBrainzClient = .shared, albumBatch: Int = 50) {
        self.store = store
        self.client = client
        self.albumBatch = max(1, albumBatch)
    }

    public func cancel() { cancelled = true }

    public func run(onProgress: @escaping @Sendable (EnrichProgress) -> Void) async {
        let total = store.count()
        guard total > 0 else { return }
        var albumsDone = 0

        // Phase A — album-level enrichment (the bulk; one MB lookup per album).
        while !cancelled {
            let albums = store.albumsNeedingMBGenres(limit: albumBatch)
            if albums.isEmpty { break }
            for group in albums {
                if cancelled { break }
                let genres = await client.genresForAlbum(artist: group.artist, album: group.album)
                try? store.setMBGenres(matchKeys: group.matchKeys, genres: genres, checkedAt: Self.now())
                albumsDone += 1
                onProgress(EnrichProgress(enriched: store.mbEnrichedCount(), checked: store.mbCheckedCount(),
                                          albums: albumsDone, total: total))
            }
        }

        // Phase B — recording-level fallback for tracks with no album (singles,
        // compilations the album lookup couldn't resolve).
        while !cancelled {
            let tracks = store.tracksNeedingMBGenres(limit: albumBatch)
            if tracks.isEmpty { break }
            for t in tracks {
                if cancelled { break }
                let genres = await client.genresForTrack(artist: t.artist ?? "", title: t.title ?? "")
                try? store.setMBGenres(matchKeys: [t.matchKey], genres: genres, checkedAt: Self.now())
                onProgress(EnrichProgress(enriched: store.mbEnrichedCount(), checked: store.mbCheckedCount(),
                                          albums: albumsDone, total: total))
            }
        }

        // Phase C — genre hierarchy for the vocabulary in use.
        await buildTaxonomy()
    }

    /// Resolve parent ("subgenre of") relations for the genres this library uses.
    /// The full ~2000-genre vocabulary is fetched once (name→MBID, cached in the
    /// taxonomy table); per-genre relation lookups run only for in-use genres, and
    /// only those not yet resolved. Roots are stamped with "" so they aren't
    /// re-queried. If MB exposes no relations, parents simply stay flat.
    func buildTaxonomy() async {
        let inUse = store.genresInUse()
        guard !inUse.isEmpty else { return }
        if store.taxonomyCount() == 0 {
            let all = await client.allGenres()
            try? store.upsertGenres(all)
        }
        for g in store.unresolvedParentGenres(inUse) {
            if cancelled { break }
            guard let mbid = store.genreMBID(g) else {
                // A free-text tag, not in the controlled vocabulary — keep it flat.
                try? store.setGenreParent(genre: g, parent: "")
                continue
            }
            if let parents = await client.parentGenres(mbid: mbid) {
                try? store.setGenreParent(genre: g, parent: parents.first ?? "")
            }
            // nil ⇒ relations unavailable; leave NULL so a later run can retry.
        }
    }

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}
