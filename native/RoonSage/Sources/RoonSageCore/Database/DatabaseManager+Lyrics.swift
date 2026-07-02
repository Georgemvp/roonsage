import Foundation
import GRDB

extension DatabaseManager {

    /// A track that still needs a lyrics lookup, with the metadata LRCLIB needs.
    public struct LyricsFetchTarget: Sendable {
        public let matchKey: String
        public let title: String
        public let artist: String?
        public let album: String?
        public let durationSec: Int?
    }

    /// Stored lyrics for a `match_key`, or `nil` when NO lookup has run yet. A row
    /// that exists but matched nothing returns a content-less `Lyrics` (not nil), so
    /// the coordinator can tell "already checked, none" from "never checked".
    public func storedLyrics(matchKey: String) -> Lyrics? {
        (try? pool.read { db -> Lyrics? in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT plain, synced, instrumental FROM track_lyrics WHERE match_key = ?",
                arguments: [matchKey]) else { return nil }
            let plain: String? = row["plain"]
            let syncedJSON: String? = row["synced"]
            let instrumental: Int? = row["instrumental"]
            let synced: [LyricLine]? = syncedJSON
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([LyricLine].self, from: $0) }
            return Lyrics(plain: plain, synced: synced, isInstrumental: (instrumental ?? 0) == 1)
        }) ?? nil
    }

    /// Insert or replace the lyrics for a `match_key`. Passing `nil` records a
    /// negative (found=0) so the backfill won't retry the track every run.
    public func upsertLyrics(matchKey: String, lyrics: Lyrics?, source: String) throws {
        let syncedJSON = lyrics?.synced
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        let found = (lyrics?.hasContent ?? false) ? 1 : 0
        let iso = ISO8601DateFormatter().string(from: Date())
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO track_lyrics (match_key, plain, synced, instrumental, found, source, fetched_at)
                VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(match_key) DO UPDATE SET
                  plain=excluded.plain, synced=excluded.synced, instrumental=excluded.instrumental,
                  found=excluded.found, source=excluded.source, fetched_at=excluded.fetched_at
                """,
                arguments: [matchKey, lyrics?.plain, syncedJSON,
                            (lyrics?.isInstrumental ?? false) ? 1 : 0, found, source, iso])
        }
    }

    /// Up to `limit` library tracks that have no `track_lyrics` row yet, newest
    /// distinct match_key first. Joined with features for the duration LRCLIB uses
    /// to disambiguate.
    public func tracksMissingLyrics(limit: Int) -> [LyricsFetchTarget] {
        (try? pool.read { db -> [LyricsFetchTarget] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.match_key AS mk, t.title AS title, t.artist AS artist, t.album AS album,
                       f.duration AS duration
                FROM tracks t
                LEFT JOIN track_lyrics l ON l.match_key = t.match_key
                LEFT JOIN track_audio_features f ON f.match_key = t.match_key
                WHERE t.match_key IS NOT NULL AND t.match_key != '' AND l.match_key IS NULL
                GROUP BY t.match_key
                LIMIT ?
                """, arguments: [limit])
            return rows.map { r in
                let dur: Double? = r["duration"]
                return LyricsFetchTarget(matchKey: r["mk"], title: r["title"] ?? "",
                                         artist: r["artist"], album: r["album"],
                                         durationSec: dur.map(Int.init))
            }
        }) ?? []
    }

    /// (tracks with matched lyrics, total distinct library tracks) — for the
    /// analyzer's coverage readout.
    public func lyricsCounts() -> (withLyrics: Int, total: Int) {
        (try? pool.read { db -> (Int, Int) in
            let found = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_lyrics WHERE found = 1") ?? 0
            let total = try Int.fetchOne(db,
                sql: "SELECT COUNT(DISTINCT match_key) FROM tracks WHERE match_key IS NOT NULL AND match_key != ''") ?? 0
            return (found, total)
        }) ?? (0, 0)
    }
}
