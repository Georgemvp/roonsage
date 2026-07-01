import Foundation

public struct PopularityProgress: Sendable {
    public var found: Int      // tracks that got a popularity value
    public var checked: Int    // tracks looked up (incl. fruitless)
    public var total: Int
}

/// Attaches Deezer's global popularity (`rank`) to analyzed tracks, analyzer-side.
/// One Deezer search per track, rate-limited in `DeezerClient` (~6 req/s).
///
/// Resumable: only un-checked rows (`popularity_checked_at IS NULL`) are queried,
/// so an interrupted run continues where it left off. Mirrors `GenreEnricher`.
public final class PopularityEnricher {
    private let store: FeatureStore
    private let client: DeezerClient
    private let batch: Int
    private var cancelled = false

    public init(store: FeatureStore, client: DeezerClient = .shared, batch: Int = 100) {
        self.store = store
        self.client = client
        self.batch = max(1, batch)
    }

    public func cancel() { cancelled = true }

    public func run(onProgress: @escaping @Sendable (PopularityProgress) -> Void) async {
        let total = store.count()
        guard total > 0 else { return }

        while !cancelled {
            let tracks = store.tracksNeedingPopularity(limit: batch)
            if tracks.isEmpty { break }
            for t in tracks {
                if cancelled { break }
                let rank = await client.popularity(artist: t.artist, title: t.title)
                try? store.setPopularity(matchKey: t.matchKey, popularity: rank, checkedAt: Self.now())
                onProgress(PopularityProgress(found: store.popularityCount(),
                                              checked: store.popularityCheckedCount(), total: total))
            }
        }
    }

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}
