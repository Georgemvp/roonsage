import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Listening history

    public func logListen(title: String, artist: String?, album: String?, zoneID: String, zoneName: String) async throws {
        let iso = Self.isoFormatter.string(from: Date())
        try await pool.write { db in
            try db.execute(
                sql: "INSERT INTO listening_history (title, artist, album, zone_id, zone_name, played_at) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [title, artist, album, zoneID, zoneName, iso]
            )
        }
    }

    public func totalListens() async throws ->Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listening_history") ?? 0
        }
    }

    public struct ListenEntry: Sendable, Codable {
        public var title: String
        public var artist: String?
        public var album: String?
        public var zoneName: String?
        public var playedAt: String
    }

    /// Top-artist play count, in a Codable shape (the tuple `topArtistsListened`
    /// returns doesn't round-trip as JSON for the client proxy).
    public struct ArtistPlayCount: Sendable, Codable {
        public var artist: String
        public var count: Int
        public init(artist: String, count: Int) { self.artist = artist; self.count = count }
    }

    /// Everything the taste-profile view needs in one payload, so a thin client
    /// can pull it from the server with a single request instead of reading its
    /// own (empty) `listening_history`.
    public struct ListenSnapshot: Sendable, Codable {
        public var total: Int
        public var topArtists: [ArtistPlayCount]
        public var recent: [ListenEntry]
        public init(total: Int, topArtists: [ArtistPlayCount], recent: [ListenEntry]) {
            self.total = total; self.topArtists = topArtists; self.recent = recent
        }
    }

    /// Builds the combined taste-profile snapshot from `listening_history`.
    public func listenSnapshot(topLimit: Int = 50, recentLimit: Int = 100) async throws -> ListenSnapshot {
        async let total = totalListens()
        async let top = topArtistsListened(limit: topLimit)
        async let recent = recentListens(limit: recentLimit)
        return try await ListenSnapshot(
            total: total,
            topArtists: top.map { ArtistPlayCount(artist: $0.artist, count: $0.count) },
            recent: recent
        )
    }

    public func recentListens(limit: Int = 50) async throws ->[ListenEntry] {
        try await pool.read { db in
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

    // MARK: - Last.fm history import

    public struct ImportedListen: Sendable {
        public var title: String
        public var artist: String
        public var album: String?
        public var playedAt: String     // ISO-8601, zelfde formaat als logListen
        public init(title: String, artist: String, album: String?, playedAt: String) {
            self.title = title; self.artist = artist; self.album = album; self.playedAt = playedAt
        }
    }

    /// Vroegste `played_at` van listens die NIET uit de opgegeven bron komen.
    /// Wordt als bovengrens gebruikt zodat de import de gaten vóór de lokale
    /// logging vult zonder de eigen Roon-listens te dupliceren.
    public func earliestListen(excludingSource source: String) async throws ->String? {
        try await pool.read { db in
            try String.fetchOne(db, sql: """
                SELECT MIN(played_at) FROM listening_history WHERE source <> ?
            """, arguments: [source])
        }
    }

    /// Meest recente `played_at` van listens van de opgegeven bron.
    /// Wordt als ondergrens (from-timestamp) gebruikt bij incrementele Last.fm-sync.
    public func latestImportedListen(source: String) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(db, sql: """
                SELECT MAX(played_at) FROM listening_history WHERE source = ?
            """, arguments: [source])
        }
    }

    /// Voegt nieuwe listens toe zonder bestaande te verwijderen. Duplicaten
    /// (zelfde source + played_at + artist) worden overgeslagen.
    public func appendImportedListens(_ entries: [ImportedListen], source: String, zoneName: String) async throws {
        try await pool.write { db in
            for e in entries {
                try db.execute(sql: """
                    INSERT INTO listening_history (title, artist, album, zone_id, zone_name, played_at, source)
                    SELECT ?, ?, ?, NULL, ?, ?, ?
                    WHERE NOT EXISTS (
                        SELECT 1 FROM listening_history
                        WHERE source = ? AND played_at = ? AND artist = ?
                    )
                """, arguments: [e.title, e.artist, e.album, zoneName, e.playedAt, source,
                                 source, e.playedAt, e.artist])
            }
        }
    }

    public func importedListenCount(source: String) async throws ->Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listening_history WHERE source = ?", arguments: [source]) ?? 0
        }
    }

    /// Vervangt alle listens van één bron in één transactie (idempotent: een
    /// her-import bouwt simpelweg opnieuw op). `zone_name` wordt de bronnaam.
    public func replaceImportedListens(_ entries: [ImportedListen], source: String, zoneName: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM listening_history WHERE source = ?", arguments: [source])
            for e in entries {
                try db.execute(sql: """
                    INSERT INTO listening_history (title, artist, album, zone_id, zone_name, played_at, source)
                    VALUES (?, ?, ?, NULL, ?, ?, ?)
                """, arguments: [e.title, e.artist, e.album, zoneName, e.playedAt, source])
            }
        }
    }

    public func topArtistsListened(limit: Int = 20) async throws ->[(artist: String, count: Int)] {
        try await pool.read { db in
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

    public func libraryStats() async throws ->LibraryStats {
        try await pool.read { db in
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

    /// Every distinct genre in the library, most-used first. Unlike
    /// `libraryStats().topGenres` (capped at 20) this is the full vocabulary, so
    /// niche genres (jazz sub-styles, world, classical sub-genres) stay
    /// selectable when mapping a request to filters.
    public func allGenres(limit: Int = 200) async throws ->[String] {
        try await pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT genre FROM track_genres
                GROUP BY genre ORDER BY COUNT(*) DESC LIMIT ?
            """, arguments: [limit])
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
    public func saveRecommendation(prompt: String, albums: [AlbumResult]) async throws ->Int64 {
        try await pool.write { db in
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

    public func listRecommendations(limit: Int = 20) async throws ->[RecommendationSummary] {
        try await pool.read { db in
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

    public func recommendationAlbums(id: Int64) async throws ->[AlbumResult] {
        try await pool.read { db in
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

    public func deleteRecommendation(id: Int64) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM recommendation_history WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Year-in-Review

    public struct YearArtist: Sendable, Codable {
        public var artist: String
        public var count: Int
        public init(artist: String, count: Int) { self.artist = artist; self.count = count }
    }

    public struct YearTrack: Sendable, Codable {
        public var title: String
        public var artist: String?
        public var count: Int
        public init(title: String, artist: String?, count: Int) {
            self.title = title; self.artist = artist; self.count = count
        }
    }

    /// Codable so a thin client can pull a year's stats from the server (its own
    /// `listening_history` is empty — only `tracks`/`track_genres` are synced).
    public struct YearStats: Sendable, Codable {
        public var year: Int
        public var totalPlays: Int
        public var uniqueArtists: Int
        public var uniqueTracks: Int
        public var topArtists: [YearArtist]
        public var topTracks: [YearTrack]
        public var playsByHour: [Int]      // index 0-23, count per hour
        public var firstListen: ListenEntry?
        public var longestStreak: Int       // consecutive days with at least 1 listen
    }

    public func yearInReview(year: Int) async throws ->YearStats {
        try await pool.read { db in
            let yearStr = "\(year)"
            let nextStr = "\(year + 1)"

            let totalPlays = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM listening_history
                WHERE played_at >= ? AND played_at < ?
            """, arguments: ["\(yearStr)-01-01", "\(nextStr)-01-01"]) ?? 0

            let uniqueArtists = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT artist) FROM listening_history
                WHERE played_at >= ? AND played_at < ? AND artist IS NOT NULL
            """, arguments: ["\(yearStr)-01-01", "\(nextStr)-01-01"]) ?? 0

            let uniqueTracks = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT title) FROM listening_history
                WHERE played_at >= ? AND played_at < ?
            """, arguments: ["\(yearStr)-01-01", "\(nextStr)-01-01"]) ?? 0

            let artistRows = try Row.fetchAll(db, sql: """
                SELECT artist, COUNT(*) as cnt FROM listening_history
                WHERE played_at >= ? AND played_at < ? AND artist IS NOT NULL
                GROUP BY artist ORDER BY cnt DESC LIMIT 8
            """, arguments: ["\(yearStr)-01-01", "\(nextStr)-01-01"])
            let topArtists = artistRows.map { YearArtist(artist: $0["artist"] as String? ?? "", count: $0["cnt"] as Int? ?? 0) }

            let trackRows = try Row.fetchAll(db, sql: """
                SELECT title, artist, COUNT(*) as cnt FROM listening_history
                WHERE played_at >= ? AND played_at < ?
                GROUP BY title, artist ORDER BY cnt DESC LIMIT 8
            """, arguments: ["\(yearStr)-01-01", "\(nextStr)-01-01"])
            let topTracks = trackRows.map { YearTrack(
                title: $0["title"] as String? ?? "",
                artist: $0["artist"] as String?,
                count: $0["cnt"] as Int? ?? 0
            )}

            // Plays per hour of day (0-23)
            var playsByHour = [Int](repeating: 0, count: 24)
            let hourRows = try Row.fetchAll(db, sql: """
                SELECT CAST(SUBSTR(played_at, 12, 2) AS INTEGER) as hr, COUNT(*) as cnt
                FROM listening_history
                WHERE played_at >= ? AND played_at < ?
                GROUP BY hr
            """, arguments: ["\(yearStr)-01-01", "\(nextStr)-01-01"])
            for row in hourRows {
                let hr = row["hr"] as Int? ?? 0
                if hr >= 0 && hr < 24 { playsByHour[hr] = row["cnt"] as Int? ?? 0 }
            }

            let firstRow = try Row.fetchOne(db, sql: """
                SELECT title, artist, album, zone_name, played_at
                FROM listening_history
                WHERE played_at >= ? AND played_at < ?
                ORDER BY played_at ASC LIMIT 1
            """, arguments: ["\(yearStr)-01-01", "\(nextStr)-01-01"])
            let firstListen = firstRow.map {
                ListenEntry(title: $0["title"] as String? ?? "",
                           artist: $0["artist"],
                           album: $0["album"],
                           zoneName: $0["zone_name"],
                           playedAt: $0["played_at"] as String? ?? "")
            }

            // Longest streak: count consecutive days with ≥1 listen
            let dayRows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT SUBSTR(played_at, 1, 10) as day
                FROM listening_history
                WHERE played_at >= ? AND played_at < ?
                ORDER BY day
            """, arguments: ["\(yearStr)-01-01", "\(nextStr)-01-01"])
            let days = dayRows.compactMap { $0["day"] as String? }
            var maxStreak = 0, currentStreak = days.isEmpty ? 0 : 1
            if days.count > 1 {
                for i in 1..<days.count {
                    if Self.isNextDay(days[i - 1], days[i]) {
                        currentStreak += 1
                    } else {
                        maxStreak = max(maxStreak, currentStreak)
                        currentStreak = 1
                    }
                }
            }
            let streak = max(maxStreak, currentStreak)

            return YearStats(
                year: year,
                totalPlays: totalPlays,
                uniqueArtists: uniqueArtists,
                uniqueTracks: uniqueTracks,
                topArtists: topArtists,
                topTracks: topTracks,
                playsByHour: playsByHour,
                firstListen: firstListen,
                longestStreak: streak
            )
        }
    }

    private static func isNextDay(_ a: String, _ b: String) -> Bool {
        guard a.count == 10, b.count == 10 else { return false }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let da = fmt.date(from: a), let db2 = fmt.date(from: b) else { return false }
        let diff = Calendar.current.dateComponents([.day], from: da, to: db2).day ?? 0
        return diff == 1
    }

    // MARK: - Album search

    public struct AlbumResult: Sendable, Hashable, Identifiable {
        public var id: String { albumKey }
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

    public func searchAlbums(query: String, limit: Int = 100) async throws ->[AlbumResult] {
        try await pool.read { db in
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

    /// Every album by one exact artist, newest releases first.
    public func albumsByArtist(_ name: String, limit: Int = 200) async throws ->[AlbumResult] {
        try await pool.read { db in
            let sql = """
                SELECT album_key, album, artist, year, COUNT(*) as track_count, MAX(image_key) as image_key
                FROM tracks
                WHERE artist = ?
                GROUP BY album_key
                ORDER BY year DESC, album LIMIT ?
            """
            let rows = try Row.fetchAll(db, sql: sql,
                arguments: StatementArguments([name, limit] as [DatabaseValueConvertible]))
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

    // MARK: - Artist search

    public struct ArtistResult: Sendable, Hashable, Identifiable {
        public var name: String
        public var trackCount: Int
        public var albumCount: Int
        public var imageKey: String?
        public var id: String { name }

        public init(name: String, trackCount: Int, albumCount: Int, imageKey: String? = nil) {
            self.name = name
            self.trackCount = trackCount
            self.albumCount = albumCount
            self.imageKey = imageKey
        }
    }

    /// Distinct library artists with track/album counts and a representative cover.
    public func searchArtists(query: String, limit: Int = 200) async throws ->[ArtistResult] {
        try await pool.read { db in
            let base = """
                SELECT artist,
                       COUNT(*) AS track_count,
                       COUNT(DISTINCT album_key) AS album_count,
                       MAX(image_key) AS image_key
                FROM tracks
                WHERE artist IS NOT NULL AND artist != ''
            """
            let sql: String
            let args: StatementArguments
            if query.isEmpty {
                sql = base + " GROUP BY artist ORDER BY artist LIMIT ?"
                args = StatementArguments([limit] as [DatabaseValueConvertible])
            } else {
                let pattern = "%\(query)%"
                sql = base + " AND LOWER(artist) LIKE LOWER(?) GROUP BY artist ORDER BY artist LIMIT ?"
                args = StatementArguments([pattern, limit] as [DatabaseValueConvertible])
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            return rows.map {
                ArtistResult(
                    name:       $0["artist"]      as String? ?? "",
                    trackCount: $0["track_count"] as Int? ?? 0,
                    albumCount: $0["album_count"] as Int? ?? 0,
                    imageKey:   $0["image_key"]
                )
            }
        }
    }

}
