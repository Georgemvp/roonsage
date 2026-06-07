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

    // MARK: - Filter tracks (curation)

    public struct FilterOptions: Sendable {
        public var genres:      [String] = []
        public var decades:     [Int]    = []
        public var artists:     [String] = []
        public var keywords:    String   = ""
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
            if options.excludeLive { conditions.append("t.is_live = 0") }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = "SELECT t.* FROM tracks t \(whereClause) ORDER BY t.artist, t.year, t.title LIMIT ?"
            args.append(options.limit)

            return try TrackRecord.fetchAll(db, sql: sql, arguments: StatementArguments(args))
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
