import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Listening history

    public func logListen(title: String, artist: String?, album: String?, zoneID: String, zoneName: String) throws {
        let iso = Self.isoFormatter.string(from: Date())
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

    // MARK: - Recommendation history

    public struct RecommendationSummary: Sendable {
        public var id: Int64
        public var prompt: String
        public var albumCount: Int
        public var createdAt: String
    }

    @discardableResult
    public func saveRecommendation(prompt: String, albums: [AlbumResult]) throws -> Int64 {
        try pool.write { db in
            let iso = Self.isoFormatter.string(from: Date())
            try db.execute(sql: "INSERT INTO recommendation_history (prompt, created_at) VALUES (?, ?)", arguments: [prompt, iso])
            let hid = db.lastInsertedRowID
            for (i, a) in albums.enumerated() {
                try db.execute(sql: """
                    INSERT INTO recommendation_albums (history_id, position, album_key, album, artist, year, image_key)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [hid, i, a.albumKey, a.album, a.artist, a.year, a.imageKey])
            }
            return hid
        }
    }

    public func listRecommendations(limit: Int = 20) throws -> [RecommendationSummary] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT h.id, h.prompt, h.created_at, COUNT(a.position) AS cnt
                FROM recommendation_history h
                LEFT JOIN recommendation_albums a ON a.history_id = h.id
                GROUP BY h.id ORDER BY h.created_at DESC LIMIT ?
            """, arguments: [limit])
            return rows.map {
                RecommendationSummary(
                    id:         $0["id"]         as Int64? ?? 0,
                    prompt:     $0["prompt"]      as String? ?? "",
                    albumCount: $0["cnt"]         as Int? ?? 0,
                    createdAt:  $0["created_at"]  as String? ?? ""
                )
            }
        }
    }

    public func recommendationAlbums(id: Int64) throws -> [AlbumResult] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT album_key, album, artist, year, image_key
                FROM recommendation_albums WHERE history_id = ? ORDER BY position
            """, arguments: [id])
            return rows.map {
                AlbumResult(
                    albumKey:   $0["album_key"] as String? ?? "",
                    album:      $0["album"]     as String? ?? "",
                    artist:     $0["artist"],
                    year:       $0["year"],
                    trackCount: 0,
                    imageKey:   $0["image_key"]
                )
            }
        }
    }

    public func deleteRecommendation(id: Int64) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM recommendation_history WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Album search

    public struct AlbumResult: Sendable {
        public var albumKey: String
        public var album: String
        public var artist: String?
        public var year: Int?
        public var trackCount: Int
        public var imageKey: String?
        public var genres: [String]

        public init(albumKey: String, album: String, artist: String?, year: Int?, trackCount: Int, imageKey: String? = nil, genres: [String] = []) {
            self.albumKey = albumKey
            self.album = album
            self.artist = artist
            self.year = year
            self.trackCount = trackCount
            self.imageKey = imageKey
            self.genres = genres
        }
    }

    public func searchAlbums(query: String, limit: Int = 100) throws -> [AlbumResult] {
        try pool.read { db in
            let sql: String
            let args: StatementArguments
            if query.isEmpty {
                sql = """
                    SELECT album_key, album, artist, year, COUNT(*) as track_count, MAX(image_key) as image_key
                    FROM tracks GROUP BY album_key
                    ORDER BY artist, year, album LIMIT ?
                """
                args = StatementArguments([limit] as [DatabaseValueConvertible])
            } else {
                let pattern = "%\(query)%"
                sql = """
                    SELECT album_key, album, artist, year, COUNT(*) as track_count, MAX(image_key) as image_key
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
                    trackCount: $0["track_count"]  as Int? ?? 0,
                    imageKey:   $0["image_key"]
                )
            }
        }
    }

}
