import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Track queries

    public func upsertTrack(_ record: TrackRecord) throws {
        try pool.write { db in
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
    public func upsertTracks(_ records: [TrackRecord]) throws {
        guard !records.isEmpty else { return }
        let chunk = Self.rowsPerChunk(columns: 9)
        try pool.write { db in
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

    public func trackCount() throws -> Int {
        try pool.read { db in
            try TrackRecord.fetchCount(db)
        }
    }

    /// True if any track row has a NULL match_key — signals that a library
    /// re-sync is needed to repopulate keys in the current format.
    public func hasNullMatchKeys() throws -> Bool {
        try pool.read { db in
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE match_key IS NULL LIMIT 1") ?? 0
            return n > 0
        }
    }

    public func searchTracks(query: String, limit: Int = 200) throws -> [TrackRecord] {
        try pool.read { db in
            if query.isEmpty {
                return try TrackRecord
                    .order(Column("title"))
                    .limit(limit)
                    .fetchAll(db)
            }
            let pattern = "%\(query)%"
            return try TrackRecord
                .filter(
                    Column("title").like(pattern) ||
                    Column("artist").like(pattern) ||
                    Column("album").like(pattern)
                )
                .order(Column("title"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Genres

    /// Rebuild `track_genres` from an albumTitle(lowercased) → [genre] mapping.
    /// Tracks are matched to genres by lowercased album title (mirrors the Python
    /// genre sync). Builds an in-memory albumLower → [trackId] index once to avoid
    /// a full table scan per album.
    public func applyGenreMapping(_ mapping: [String: [String]]) throws {
        try pool.write { db in
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

    public func genreCount() throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT genre) FROM track_genres") ?? 0
        }
    }

}
