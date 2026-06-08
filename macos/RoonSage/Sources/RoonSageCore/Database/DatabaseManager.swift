import Foundation
import GRDB

/// Manages the GRDB DatabasePool with WAL mode and schema migrations.
/// Thread-safe; GRDB's DatabasePool handles concurrent reads natively.
public final class DatabaseManager: Sendable {

    public let pool: DatabasePool

    public init(url: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
        }
        let p = try DatabasePool(path: url.path, configuration: config)
        pool = p
        try Schema.migrate(p)
    }

    // MARK: - Track queries

    public func upsertTrack(_ record: TrackRecord) throws {
        try pool.write { db in
            try record.save(db)
        }
    }

    public func upsertTracks(_ records: [TrackRecord]) throws {
        try pool.write { db in
            for record in records {
                try record.save(db)
            }
        }
    }

    public func trackCount() throws -> Int {
        try pool.read { db in
            try TrackRecord.fetchCount(db)
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

    public func clearTracks() throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM tracks")
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

            for (albumLower, genres) in mapping {
                guard let trackIds = albumToTracks[albumLower] else { continue }
                for trackId in trackIds {
                    for genre in genres {
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO track_genres (track_id, genre) VALUES (?, ?)",
                            arguments: [trackId, genre]
                        )
                    }
                }
            }
        }
    }

    public func genreCount() throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT genre) FROM track_genres") ?? 0
        }
    }

    // MARK: - Listening history

    public func logListen(title: String, artist: String?, album: String?, zoneID: String, zoneName: String) throws {
        let iso = ISO8601DateFormatter().string(from: Date())
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO listening_history (title, artist, album, zone_id, zone_name, played_at) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [title, artist, album, zoneID, zoneName, iso]
            )
        }
    }

    public func totalListens() throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listening_history") ?? 0
        }
    }

    public struct ListenEntry: Sendable {
        public var title: String
        public var artist: String?
        public var album: String?
        public var zoneName: String?
        public var playedAt: String
    }

    public func recentListens(limit: Int = 50) throws -> [ListenEntry] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT title, artist, album, zone_name, played_at
                FROM listening_history ORDER BY played_at DESC LIMIT ?
            """, arguments: [limit])
            return rows.map {
                ListenEntry(
                    title:    $0["title"]     as String? ?? "",
                    artist:   $0["artist"],
                    album:    $0["album"],
                    zoneName: $0["zone_name"],
                    playedAt: $0["played_at"] as String? ?? ""
                )
            }
        }
    }

    public func topArtistsListened(limit: Int = 20) throws -> [(artist: String, count: Int)] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT artist, COUNT(*) as cnt FROM listening_history
                WHERE artist IS NOT NULL GROUP BY artist ORDER BY cnt DESC LIMIT ?
            """, arguments: [limit])
            return rows.map { (artist: $0["artist"] as String? ?? "", count: $0["cnt"] as Int? ?? 0) }
        }
    }

    // MARK: - Library stats

    public struct LibraryStats: Sendable {
        public var totalTracks: Int
        public var totalArtists: Int
        public var totalAlbums: Int
        public var topGenres: [(genre: String, count: Int)]
        public var tracksByDecade: [(decade: String, count: Int)]
    }

    public func libraryStats() throws -> LibraryStats {
        try pool.read { db in
            let totalTracks  = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") ?? 0
            let totalArtists = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT artist) FROM tracks WHERE artist IS NOT NULL") ?? 0
            let totalAlbums  = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT album_key) FROM tracks") ?? 0

            let genreRows = try Row.fetchAll(db, sql: """
                SELECT genre, COUNT(*) as cnt FROM track_genres
                GROUP BY genre ORDER BY cnt DESC LIMIT 20
            """)
            let topGenres = genreRows.map { (genre: $0["genre"] as String? ?? "", count: $0["cnt"] as Int? ?? 0) }

            let decadeRows = try Row.fetchAll(db, sql: """
                SELECT (year/10)*10 as decade, COUNT(*) as cnt
                FROM tracks WHERE year IS NOT NULL AND year > 1900
                GROUP BY decade ORDER BY decade
            """)
            let tracksByDecade = decadeRows.map { row -> (decade: String, count: Int) in
                let d = row["decade"] as Int? ?? 0
                return (decade: "\(d)s", count: row["cnt"] as Int? ?? 0)
            }

            return LibraryStats(
                totalTracks: totalTracks, totalArtists: totalArtists, totalAlbums: totalAlbums,
                topGenres: topGenres, tracksByDecade: tracksByDecade
            )
        }
    }

    // MARK: - Album search

    public struct AlbumResult: Sendable {
        public var albumKey: String
        public var album: String
        public var artist: String?
        public var year: Int?
        public var trackCount: Int
    }

    public func searchAlbums(query: String, limit: Int = 100) throws -> [AlbumResult] {
        try pool.read { db in
            let sql: String
            let args: StatementArguments
            if query.isEmpty {
                sql = """
                    SELECT album_key, album, artist, year, COUNT(*) as track_count
                    FROM tracks GROUP BY album_key
                    ORDER BY artist, year, album LIMIT ?
                """
                args = StatementArguments([limit] as [DatabaseValueConvertible])
            } else {
                let pattern = "%\(query)%"
                sql = """
                    SELECT album_key, album, artist, year, COUNT(*) as track_count
                    FROM tracks
                    WHERE LOWER(album) LIKE LOWER(?) OR LOWER(artist) LIKE LOWER(?)
                    GROUP BY album_key
                    ORDER BY artist, year, album LIMIT ?
                """
                args = StatementArguments([pattern, pattern, limit] as [DatabaseValueConvertible])
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            return rows.map {
                AlbumResult(
                    albumKey:   $0["album_key"]   as String? ?? "",
                    album:      $0["album"]        as String? ?? "",
                    artist:     $0["artist"],
                    year:       $0["year"],
                    trackCount: $0["track_count"]  as Int? ?? 0
                )
            }
        }
    }

    // MARK: - Filter tracks (curation)

    public struct FilterOptions: Sendable {
        public var genres:      [String] = []
        public var decades:     [Int]    = []
        public var artists:     [String] = []
        public var keywords:    String   = ""
        public var albumKey:    String?  = nil
        public var excludeLive: Bool     = true
        public var limit:       Int      = 500
        public init() {}
    }

    public func filterTracks(options: FilterOptions) throws -> [TrackRecord] {
        try pool.read { db in
            var conditions: [String] = []
            var args: [DatabaseValueConvertible] = []

            if !options.genres.isEmpty {
                let ph = options.genres.map { _ in "?" }.joined(separator: ",")
                conditions.append("t.id IN (SELECT track_id FROM track_genres WHERE genre IN (\(ph)))")
                args.append(contentsOf: options.genres as [DatabaseValueConvertible])
            }
            if !options.decades.isEmpty {
                let dc = options.decades.map { _ in "(t.year >= ? AND t.year < ?)" }.joined(separator: " OR ")
                conditions.append("(\(dc))")
                for d in options.decades { args.append(d); args.append(d + 10) }
            }
            if !options.artists.isEmpty {
                let ac = options.artists.map { _ in "LOWER(t.artist) LIKE LOWER(?)" }.joined(separator: " OR ")
                conditions.append("(\(ac))")
                args.append(contentsOf: options.artists.map { "%\($0)%" as DatabaseValueConvertible })
            }
            if !options.keywords.isEmpty {
                conditions.append("(LOWER(t.title) LIKE LOWER(?) OR LOWER(t.artist) LIKE LOWER(?) OR LOWER(t.album) LIKE LOWER(?))")
                let kw: DatabaseValueConvertible = "%\(options.keywords)%"
                args.append(contentsOf: [kw, kw, kw])
            }
            if let key = options.albumKey {
                conditions.append("t.album_key = ?")
                args.append(key as DatabaseValueConvertible)
            }
            if options.excludeLive { conditions.append("t.is_live = 0") }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = "SELECT t.* FROM tracks t \(whereClause) ORDER BY t.artist, t.year, t.title LIMIT ?"
            args.append(options.limit)

            return try TrackRecord.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    // MARK: - Playlists

    public struct PlaylistSummary: Sendable {
        public var id: Int64
        public var name: String
        public var trackCount: Int
        public var createdAt: String
    }

    public func savePlaylist(name: String, tracks: [TrackRecord]) throws -> Int64 {
        try pool.write { db in
            let iso = ISO8601DateFormatter().string(from: Date())
            try db.execute(sql: "INSERT INTO playlists (name, created_at) VALUES (?, ?)", arguments: [name, iso])
            let pid = db.lastInsertedRowID
            for (i, t) in tracks.enumerated() {
                try db.execute(sql: """
                    INSERT INTO playlist_tracks (playlist_id, position, track_id, title, artist, album, album_key, year, is_live)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [pid, i, t.id, t.title, t.artist, t.album, t.albumKey, t.year, t.isLive])
            }
            return pid
        }
    }

    public func listPlaylists() throws -> [PlaylistSummary] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.id, p.name, p.created_at, COUNT(pt.position) AS cnt
                FROM playlists p LEFT JOIN playlist_tracks pt ON pt.playlist_id = p.id
                GROUP BY p.id ORDER BY p.created_at DESC
            """)
            return rows.map {
                PlaylistSummary(
                    id: $0["id"] as Int64? ?? 0,
                    name: $0["name"] as String? ?? "",
                    trackCount: $0["cnt"] as Int? ?? 0,
                    createdAt: $0["created_at"] as String? ?? ""
                )
            }
        }
    }

    /// Saved tracks as stored (track_id may be stale after a resync).
    public func playlistTracks(id: Int64) throws -> [TrackRecord] {
        try pool.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT track_id AS id, title, artist, album, album_key, year, is_live
                FROM playlist_tracks WHERE playlist_id = ? ORDER BY position
            """, arguments: [id])
        }
    }

    public func deletePlaylist(id: Int64) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM playlists WHERE id = ?", arguments: [id])
        }
    }

    /// Re-resolve a saved track to a CURRENT library track (Roon item_keys change
    /// across resyncs). Matches by title + artist, case-insensitive.
    public func resolveCurrentTracks(_ saved: [TrackRecord]) throws -> [TrackRecord] {
        try pool.read { db in
            var resolved: [TrackRecord] = []
            for t in saved {
                let current = try TrackRecord.fetchOne(db, sql: """
                    SELECT * FROM tracks
                    WHERE LOWER(title) = LOWER(?)
                      AND (? IS NULL OR artist IS NULL OR LOWER(artist) = LOWER(?))
                    LIMIT 1
                """, arguments: [t.title, t.artist, t.artist])
                if let current { resolved.append(current) }
            }
            return resolved
        }
    }

    // MARK: - Discovery (cache-only sections)

    /// Albums with no matching entry in listening history — never played here.
    public func undiscoveredAlbums(limit: Int = 16) throws -> [AlbumResult] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT album_key, album, artist, year, COUNT(*) AS track_count
                FROM tracks
                WHERE album IS NOT NULL AND album <> ''
                  AND LOWER(album) NOT IN (
                      SELECT LOWER(album) FROM listening_history WHERE album IS NOT NULL
                  )
                GROUP BY album_key
                HAVING track_count >= 3
                ORDER BY RANDOM()
                LIMIT ?
            """, arguments: [limit])
            return rows.map {
                AlbumResult(
                    albumKey:   $0["album_key"]   as String? ?? "",
                    album:      $0["album"]        as String? ?? "",
                    artist:     $0["artist"],
                    year:       $0["year"],
                    trackCount: $0["track_count"]  as Int? ?? 0
                )
            }
        }
    }

    /// Tracks you used to play but haven't in the last `days` days, max 2 per
    /// artist, most-played first. Resolved to current library item_keys.
    public func forgottenFavorites(days: Int = 60, limit: Int = 20) throws -> [TrackRecord] {
        try pool.read { db in
            let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(days) * 86_400))
            let rows = try Row.fetchAll(db, sql: """
                SELECT title, artist, MAX(played_at) AS last_play, COUNT(*) AS plays
                FROM listening_history
                WHERE artist IS NOT NULL
                GROUP BY LOWER(title), LOWER(artist)
                HAVING last_play < ?
                ORDER BY plays DESC, last_play ASC
            """, arguments: [cutoff])

            var perArtist: [String: Int] = [:]
            var result: [TrackRecord] = []
            for row in rows {
                let title = row["title"] as String? ?? ""
                let artist = row["artist"] as String? ?? ""
                let aKey = artist.lowercased()
                if perArtist[aKey, default: 0] >= 2 { continue }
                if let t = try TrackRecord.fetchOne(db, sql: """
                    SELECT * FROM tracks WHERE LOWER(title) = LOWER(?) AND LOWER(artist) = LOWER(?) LIMIT 1
                """, arguments: [title, artist]) {
                    perArtist[aKey, default: 0] += 1
                    result.append(t)
                    if result.count >= limit { break }
                }
            }
            return result
        }
    }

    /// Your most-played tracks (from listening history), resolved to current
    /// library item_keys.
    public func topTracks(limit: Int = 25) throws -> [TrackRecord] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT title, artist, COUNT(*) AS plays
                FROM listening_history WHERE artist IS NOT NULL
                GROUP BY LOWER(title), LOWER(artist)
                ORDER BY plays DESC LIMIT ?
            """, arguments: [limit])
            var result: [TrackRecord] = []
            for row in rows {
                let title = row["title"] as String? ?? ""
                let artist = row["artist"] as String? ?? ""
                if let t = try TrackRecord.fetchOne(db, sql: """
                    SELECT * FROM tracks WHERE LOWER(title) = LOWER(?) AND LOWER(artist) = LOWER(?) LIMIT 1
                """, arguments: [title, artist]) {
                    result.append(t)
                }
            }
            return result
        }
    }

    // MARK: - Sync state

    public func syncStateValue(forKey key: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [key])
        }
    }

    public func setSyncState(key: String, value: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }
}
