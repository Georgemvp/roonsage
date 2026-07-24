import Foundation

/// A recency-decay discovery axis over the OWNED library: albums you loved and
/// forgot, albums you've never heard, and a deterministic "album of the day".
/// Distinct from the sonic-similarity surfaces — this one only asks "when did you
/// last hear this?". Pure scoring lives in `ForgottenScore`; this orchestrates the
/// local GRDB reads. Every query reuses cached library data — it never hits Roon.
public struct ForgottenMusicService: Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) { self.database = database }

    /// Owned albums ranked by how "forgotten" they are (recency-decay of the last
    /// play, nudged up by past play depth), most-forgotten first. Max one per artist
    /// so the shelf spans your history rather than one artist's back catalogue.
    /// Never-played albums are handled separately by `neverPlayedAlbums`.
    public func forgottenAlbums(now: Date = Date(), limit: Int = 16) async throws -> [DatabaseManager.AlbumResult] {
        let aggregates = try await database.playedAlbumAggregates()
        // These rows all played at least once; a nil timestamp means an
        // unparseable played_at, NOT "never played", so floor it to the distant past
        // rather than letting `score` hand it the never-played ceiling of 1.0.
        let scored = aggregates
            .map { agg -> (album: DatabaseManager.AlbumResult, score: Double) in
                let last = agg.lastPlayedAt ?? Date(timeIntervalSince1970: 0)
                return (agg.album, ForgottenScore.score(lastPlayedAt: last, now: now, playCount: agg.playCount))
            }
            .sorted { $0.score > $1.score }

        var perArtist: [String: Int] = [:]
        var out: [DatabaseManager.AlbumResult] = []
        for item in scored {
            let artistKey = (item.album.artist ?? "").lowercased()
            if perArtist[artistKey, default: 0] >= 1 { continue }
            perArtist[artistKey, default: 0] += 1
            out.append(item.album)
            if out.count >= limit { break }
        }
        return out
    }

    /// Owned albums with no play in listening history at all — "nog niet gehoord".
    /// Delegates to the shared `undiscoveredAlbums` query (also used by the library
    /// browse), so this axis and that one never diverge.
    public func neverPlayedAlbums(limit: Int = 16) async throws -> [DatabaseManager.AlbumResult] {
        try await database.undiscoveredAlbums(limit: limit)
    }

    /// One deterministic pick for a calendar day: the same date always yields the
    /// same album, the next day a different one. Drawn from the most-forgotten owned
    /// albums, falling back to never-played albums if you've played everything.
    /// Returns nil only when the library has no eligible albums at all.
    public func albumOfTheDay(on date: Date) async throws -> DatabaseManager.AlbumResult? {
        // Score the pool against the START of the day so every open on the same
        // (UTC) calendar day sees an identical ordering — a continuously-drifting
        // `now` would let the pick change between a morning and an evening open.
        let dayReference = ForgottenScore.calendar.startOfDay(for: date)
        var pool = try await forgottenAlbums(now: dayReference, limit: 30)
        if pool.isEmpty { pool = try await neverPlayedAlbums(limit: 30) }
        guard !pool.isEmpty else { return nil }
        return pool[ForgottenScore.pickIndex(for: date, count: pool.count)]
    }
}
