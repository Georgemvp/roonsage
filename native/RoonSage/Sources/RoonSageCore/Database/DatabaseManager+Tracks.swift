import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Track queries

    public func upsertTrack(_ record: TrackRecord) async throws {
        try await pool.write { db in
            try record.save(db)
        }
    }

    /// Largest number of bound parameters we put in one statement. SQLite's
    /// historical limit is 999; staying under it keeps us portable across SQLite
    /// builds. Rows per chunk = this / columns-per-row.
    static let maxBoundParams = 900

    static func rowsPerChunk(columns: Int) -> Int { max(1, maxBoundParams / columns) }

    /// Multi-row upsert (one statement per chunk) — far fewer VDBE round-trips
    /// than a per-record `save()` loop on a full-library sync.
    public func upsertTracks(_ records: [TrackRecord]) async throws {
        guard !records.isEmpty else { return }
        let chunk = Self.rowsPerChunk(columns: 9)
        try await pool.write { db in
            var start = 0
            while start < records.count {
                let slice = records[start..<min(start + chunk, records.count)]
                let placeholders = slice.map { _ in "(?,?,?,?,?,?,?,?,?)" }.joined(separator: ",")
                let sql = """
                    INSERT INTO tracks
                      (id, title, artist, album, album_key, year, is_live, match_key, image_key)
                    VALUES \(placeholders)
                    ON CONFLICT(id) DO UPDATE SET
                      title=excluded.title, artist=excluded.artist, album=excluded.album,
                      album_key=excluded.album_key, year=excluded.year, is_live=excluded.is_live,
                      match_key=excluded.match_key, image_key=excluded.image_key
                """
                var args: [DatabaseValueConvertible?] = []
                args.reserveCapacity(slice.count * 9)
                for r in slice {
                    args.append(contentsOf: [r.id, r.title, r.artist, r.album, r.albumKey,
                                             r.year, r.isLive, r.matchKey, r.imageKey] as [DatabaseValueConvertible?])
                }
                try db.execute(sql: sql, arguments: StatementArguments(args))
                start += chunk
            }
        }
    }

    public func trackCount() async throws ->Int {
        try await pool.read { db in
            try TrackRecord.fetchCount(db)
        }
    }

    /// True if any track row has a NULL match_key — signals that a library
    /// re-sync is needed to repopulate keys in the current format.
    public func hasNullMatchKeys() async throws ->Bool {
        try await pool.read { db in
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE match_key IS NULL LIMIT 1") ?? 0
            return n > 0
        }
    }

    /// Build a prefix-matching FTS5 query from raw user text. Each token is
    /// double-quoted so user input can never inject FTS operators (AND, OR,
    /// NEAR, '-', column filters). Returns nil when the text holds no
    /// searchable token (then callers skip the text constraint entirely).
    static func ftsQuery(_ raw: String) -> String? {
        let tokens = raw.split { !$0.isLetter && !$0.isNumber }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    public func searchTracks(query: String, limit: Int = 200) async throws ->[TrackRecord] {
        try await pool.read { db in
            guard let match = Self.ftsQuery(query) else {
                return try TrackRecord
                    .order(Column("title"))
                    .limit(limit)
                    .fetchAll(db)
            }
            // FTS5 index lookup (ordered by relevance) — replaces the
            // leading-wildcard LIKE that scanned the whole table.
            return try TrackRecord.fetchAll(db, sql: """
                SELECT t.* FROM tracks t
                JOIN tracks_fts ON tracks_fts.rowid = t.rowid
                WHERE tracks_fts MATCH ?
                ORDER BY rank LIMIT ?
            """, arguments: [match, limit])
        }
    }

    // MARK: - Genres

    /// Rebuild `track_genres` from an albumTitle(lowercased) → [genre] mapping.
    /// Tracks are matched to genres by lowercased album title (mirrors the Python
    /// genre sync). Builds an in-memory albumLower → [trackId] index once to avoid
    /// a full table scan per album.
    public func applyGenreMapping(_ mapping: [String: [String]]) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM track_genres")

            var albumToTracks: [String: [String]] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT id, album FROM tracks WHERE album IS NOT NULL")
            for row in rows {
                guard let id = row["id"] as String?, !id.isEmpty else { continue }
                let albumLower = (row["album"] as String? ?? "")
                    .trimmingCharacters(in: .whitespaces).lowercased()
                guard !albumLower.isEmpty else { continue }
                albumToTracks[albumLower, default: []].append(id)
            }

            var pairs: [(String, String)] = []
            for (albumLower, genres) in mapping {
                guard let trackIds = albumToTracks[albumLower] else { continue }
                for trackId in trackIds {
                    for genre in genres { pairs.append((trackId, genre)) }
                }
            }
            // Batch multi-row insert (was one statement per track-genre pair —
            // tens of thousands on a large library).
            let chunk = Self.rowsPerChunk(columns: 2)
            var start = 0
            while start < pairs.count {
                let slice = pairs[start..<min(start + chunk, pairs.count)]
                let placeholders = slice.map { _ in "(?,?)" }.joined(separator: ",")
                var args: [DatabaseValueConvertible] = []
                args.reserveCapacity(slice.count * 2)
                for p in slice { args.append(p.0); args.append(p.1) }
                try db.execute(
                    sql: "INSERT OR IGNORE INTO track_genres (track_id, genre) VALUES \(placeholders)",
                    arguments: StatementArguments(args)
                )
                start += chunk
            }
        }
    }

    public func genreCount() async throws ->Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT genre) FROM track_genres") ?? 0
        }
    }

    /// Roon genres keyed by track id, for genre-affinity ranking (artist radios).
    /// One pass over `track_genres`; cheap enough to load whole.
    public func genresByTrackID() async throws -> [String: Set<String>] {
        try await pool.read { db in
            var map: [String: Set<String>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT track_id, genre FROM track_genres") {
                guard let id = row["track_id"] as String?, let g = row["genre"] as String? else { continue }
                map[id, default: []].insert(g)
            }
            return map
        }
    }

    /// Returns a mapping of albumKey → [genre] for the given album keys.
    public func genresForAlbumKeys(_ keys: [String]) async throws ->[String: [String]] {
        guard !keys.isEmpty else { return [:] }
        return try await pool.read { db in
            let ph = keys.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT t.album_key, tg.genre
                FROM track_genres tg JOIN tracks t ON t.id = tg.track_id
                WHERE t.album_key IN (\(ph))
            """, arguments: StatementArguments(keys as [DatabaseValueConvertible]))
            var result: [String: [String]] = [:]
            for row in rows {
                guard let k = row["album_key"] as String?, let g = row["genre"] as String? else { continue }
                result[k, default: []].append(g)
            }
            return result
        }
    }

}
