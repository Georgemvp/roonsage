import Foundation
import GRDB

// MARK: - Unanalyzed library tracks (preview-embedding backfill feed)

extension DatabaseManager {

    /// One library track that has no analyzed audio features — typically a
    /// Qobuz-added track with no local file. Feed for the analyzer's
    /// preview-embedding backfill.
    public struct UnanalyzedTrack: Sendable {
        public let matchKey: String
        public let title: String
        public let artist: String?
        public let album: String?
    }

    /// Library tracks (deduped by content key) without a feature row, oldest-id
    /// order for a stable walk (`offset` pages through the backlog — a caller
    /// that filters out already-attempted keys must advance it, or the same
    /// negative-cached page returns forever). Live recordings are excluded — a
    /// 30s preview of a *studio* cut would mis-embed them anyway.
    public func tracksWithoutFeatures(limit: Int, offset: Int = 0) async throws -> [UnanalyzedTrack] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.match_key AS mk, MIN(t.title) AS title, MIN(t.artist) AS artist, MIN(t.album) AS album
                FROM tracks t
                LEFT JOIN track_audio_features f ON t.match_key = f.match_key
                WHERE t.match_key IS NOT NULL AND t.match_key != ''
                  AND f.match_key IS NULL AND t.is_live = 0
                GROUP BY t.match_key
                ORDER BY MIN(t.rowid)
                LIMIT ? OFFSET ?
            """, arguments: [limit, offset])
            return rows.compactMap { r in
                guard let mk = r["mk"] as String?, let title = r["title"] as String?, !title.isEmpty
                else { return nil }
                return UnanalyzedTrack(matchKey: mk, title: title,
                                       artist: r["artist"], album: r["album"])
            }
        }
    }

    /// How many content-distinct library tracks still lack features (the
    /// preview backfill's backlog meter).
    public func tracksWithoutFeaturesCount() async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT t.match_key)
                FROM tracks t
                LEFT JOIN track_audio_features f ON t.match_key = f.match_key
                WHERE t.match_key IS NOT NULL AND t.match_key != ''
                  AND f.match_key IS NULL AND t.is_live = 0
            """) ?? 0
        }
    }
}

extension RoonClient {
    /// Public feed for the analyzer app's preview-embedding backfill: library
    /// tracks with no analyzed features (server-of-record only).
    public func unanalyzedTracks(limit: Int, offset: Int = 0) async -> [DatabaseManager.UnanalyzedTrack] {
        guard !isRemote, let db = database else { return [] }
        return (try? await db.tracksWithoutFeatures(limit: limit, offset: offset)) ?? []
    }

    public func unanalyzedTrackCount() async -> Int {
        guard !isRemote, let db = database else { return 0 }
        return (try? await db.tracksWithoutFeaturesCount()) ?? 0
    }
}
