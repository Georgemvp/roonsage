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

    /// Largest number of bound parameters we put in one statement. SQLite's
    /// historical limit is 999; staying under it keeps us portable across SQLite
    /// builds. Rows per chunk = this / columns-per-row.
    private static let maxBoundParams = 900

    private static func rowsPerChunk(columns: Int) -> Int { max(1, maxBoundParams / columns) }

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
        public var imageKey: String?

        public init(albumKey: String, album: String, artist: String?, year: Int?, trackCount: Int, imageKey: String? = nil) {
            self.albumKey = albumKey
            self.album = album
            self.artist = artist
            self.year = year
            self.trackCount = trackCount
            self.imageKey = imageKey
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

    // MARK: - Filter tracks (curation)

    public struct FilterOptions: Sendable {
        public var genres:      [String] = []
        public var decades:     [Int]    = []
        public var artists:     [String] = []
        public var keywords:    String   = ""
        public var tags:        [String] = []   // LLM audio tags (matched via track_audio_features)
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
            if !options.tags.isEmpty {
                let tc = options.tags.map { _ in "LOWER(f.tags) LIKE ?" }.joined(separator: " OR ")
                conditions.append("t.match_key IN (SELECT match_key FROM track_audio_features f WHERE \(tc))")
                args.append(contentsOf: options.tags.map { "%\"\($0.lowercased())\"%" as DatabaseValueConvertible })
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
            let chunk = Self.rowsPerChunk(columns: 9)
            var start = 0
            while start < tracks.count {
                let end = min(start + chunk, tracks.count)
                let placeholders = (start..<end).map { _ in "(?,?,?,?,?,?,?,?,?)" }.joined(separator: ",")
                var args: [DatabaseValueConvertible?] = []
                args.reserveCapacity((end - start) * 9)
                for i in start..<end {
                    let t = tracks[i]
                    args.append(contentsOf: [pid, i, t.id, t.title, t.artist, t.album, t.albumKey, t.year, t.isLive] as [DatabaseValueConvertible?])
                }
                try db.execute(sql: """
                    INSERT INTO playlist_tracks
                      (playlist_id, position, track_id, title, artist, album, album_key, year, is_live)
                    VALUES \(placeholders)
                """, arguments: StatementArguments(args))
                start += chunk
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
        guard !saved.isEmpty else { return [] }
        return try pool.read { db in
            // One query fetching every candidate by title, then resolve in-memory
            // (was one SELECT per saved track).
            let titles = Array(Set(saved.map { $0.title.lowercased() }))
            var byTitle: [String: [TrackRecord]] = [:]
            let chunk = Self.rowsPerChunk(columns: 1)
            var start = 0
            while start < titles.count {
                let slice = titles[start..<min(start + chunk, titles.count)]
                let ph = slice.map { _ in "?" }.joined(separator: ",")
                let rows = try TrackRecord.fetchAll(
                    db, sql: "SELECT * FROM tracks WHERE LOWER(title) IN (\(ph))",
                    arguments: StatementArguments(Array(slice) as [DatabaseValueConvertible])
                )
                for r in rows { byTitle[r.title.lowercased(), default: []].append(r) }
                start += chunk
            }
            return saved.compactMap { s in
                let candidates = byTitle[s.title.lowercased()] ?? []
                let savedArtist = s.artist?.lowercased()
                // Mirror the old WHERE: match when saved artist is nil, the
                // library artist is nil, or both match (case-insensitive).
                return candidates.first { c in
                    savedArtist == nil || c.artist == nil || c.artist?.lowercased() == savedArtist
                }
            }
        }
    }

    // MARK: - Discovery (cache-only sections)

    /// Albums with no matching entry in listening history — never played here.
    public func undiscoveredAlbums(limit: Int = 16) throws -> [AlbumResult] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT album_key, album, artist, year, COUNT(*) AS track_count, MAX(image_key) as image_key
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
                    trackCount: $0["track_count"]  as Int? ?? 0,
                    imageKey:   $0["image_key"]
                )
            }
        }
    }

    /// Tracks you used to play but haven't in the last `days` days, max 2 per
    /// artist, most-played first. Resolved to current library item_keys.
    public func forgottenFavorites(days: Int = 60, limit: Int = 20) throws -> [TrackRecord] {
        try pool.read { db in
            let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(days) * 86_400))
            // Single JOIN: history aggregate → current library track (was an
            // N+1 point-lookup per history row). 2-per-artist cap stays in Swift.
            let rows = try TrackRecord.fetchAll(db, sql: """
                SELECT t.* FROM tracks t
                JOIN (
                    SELECT title, artist, MAX(played_at) AS last_play, COUNT(*) AS plays
                    FROM listening_history
                    WHERE artist IS NOT NULL
                    GROUP BY LOWER(title), LOWER(artist)
                    HAVING last_play < ?
                ) h ON LOWER(t.title) = LOWER(h.title) AND LOWER(t.artist) = LOWER(h.artist)
                GROUP BY LOWER(t.title), LOWER(t.artist)
                ORDER BY h.plays DESC, h.last_play ASC
            """, arguments: [cutoff])

            var perArtist: [String: Int] = [:]
            var result: [TrackRecord] = []
            for t in rows {
                let aKey = (t.artist ?? "").lowercased()
                if perArtist[aKey, default: 0] >= 2 { continue }
                perArtist[aKey, default: 0] += 1
                result.append(t)
                if result.count >= limit { break }
            }
            return result
        }
    }

    /// Your most-played tracks (from listening history), resolved to current
    /// library item_keys.
    public func topTracks(limit: Int = 25) throws -> [TrackRecord] {
        try pool.read { db in
            // Single JOIN instead of N+1 per-row lookups.
            return try TrackRecord.fetchAll(db, sql: """
                SELECT t.* FROM tracks t
                JOIN (
                    SELECT title, artist, COUNT(*) AS plays
                    FROM listening_history WHERE artist IS NOT NULL
                    GROUP BY LOWER(title), LOWER(artist)
                    ORDER BY plays DESC LIMIT ?
                ) h ON LOWER(t.title) = LOWER(h.title) AND LOWER(t.artist) = LOWER(h.artist)
                GROUP BY LOWER(t.title), LOWER(t.artist)
                ORDER BY h.plays DESC
            """, arguments: [limit])
        }
    }

    // MARK: - Library browse (tracks + audio features + tags)

    public struct LibraryTrackRow: Sendable, Identifiable {
        public var id: String
        public var title: String
        public var artist: String?
        public var album: String?
        public var year: Int?
        public var isLive: Bool
        public var imageKey: String?
        public var bpm: Double?
        public var camelot: String?
        public var tags: [String]
    }

    /// Tracks (left-joined with audio features) filtered by free-text query and
    /// an optional tag. Returns title/artist/album + bpm/camelot/tags when known.
    public func browseTracks(query: String, tag: String?, limit: Int = 300) throws -> [LibraryTrackRow] {
        try pool.read { db in
            var conditions: [String] = []
            var args: [DatabaseValueConvertible] = []
            if !query.isEmpty {
                conditions.append("(LOWER(t.title) LIKE ? OR LOWER(t.artist) LIKE ? OR LOWER(t.album) LIKE ?)")
                let p = "%\(query.lowercased())%"
                args.append(contentsOf: [p, p, p])
            }
            if let tag, !tag.isEmpty {
                conditions.append("LOWER(f.tags) LIKE ?")
                args.append("%\"\(tag.lowercased())\"%")
            }
            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let sql = """
                SELECT t.id, t.title, t.artist, t.album, t.year, t.is_live, t.image_key, f.bpm, f.camelot, f.tags
                FROM tracks t LEFT JOIN track_audio_features f ON t.match_key = f.match_key
                \(whereClause)
                ORDER BY t.artist, t.year, t.title LIMIT ?
            """
            args.append(limit)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { r in
                var tags: [String] = []
                if let t = r["tags"] as String?, let data = t.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                    tags = arr.compactMap { $0 as? String }
                }
                return LibraryTrackRow(
                    id: r["id"] ?? "", title: r["title"] ?? "", artist: r["artist"], album: r["album"],
                    year: r["year"], isLive: (r["is_live"] as Bool?) ?? false,
                    imageKey: r["image_key"],
                    bpm: r["bpm"], camelot: r["camelot"], tags: tags
                )
            }
        }
    }

    /// Most common LLM tags (parsed from the JSON arrays), for filter chips.
    public func topTags(limit: Int = 30) throws -> [(tag: String, count: Int)] {
        try pool.read { db in
            let rows = try String.fetchAll(db, sql: "SELECT tags FROM track_audio_features WHERE tags IS NOT NULL")
            var counts: [String: Int] = [:]
            for json in rows {
                guard let data = json.data(using: .utf8),
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { continue }
                for case let t as String in arr { counts[t.lowercased(), default: 0] += 1 }
            }
            return counts.sorted { $0.value > $1.value }.prefix(limit).map { (tag: $0.key, count: $0.value) }
        }
    }

    // MARK: - Audio features (synced from the native analyzer)

    public struct AudioFeatureRow: Sendable {
        public var matchKey: String
        public var bpm: Double?
        public var camelot: String?
        public var keyRoot: String?
        public var keyMode: String?
        public var energy: Double?
        public var duration: Double?
        public var tags: String?
        public init(matchKey: String, bpm: Double?, camelot: String?, keyRoot: String?,
                    keyMode: String?, energy: Double?, duration: Double?, tags: String?) {
            self.matchKey = matchKey; self.bpm = bpm; self.camelot = camelot; self.keyRoot = keyRoot
            self.keyMode = keyMode; self.energy = energy; self.duration = duration; self.tags = tags
        }
    }

    /// Audio features for one track by its content match key (for Now Playing).
    public func featuresForMatchKey(_ matchKey: String) -> (bpm: Double, camelot: String, tags: [String])? {
        (try? pool.read { db -> (Double, String, [String])? in
            guard let r = try Row.fetchOne(db, sql: "SELECT bpm, camelot, tags FROM track_audio_features WHERE match_key = ?", arguments: [matchKey]) else { return nil }
            var tags: [String] = []
            if let t = r["tags"] as String?, let d = t.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: d) as? [Any] { tags = arr.compactMap { $0 as? String } }
            return (r["bpm"] ?? 0, r["camelot"] ?? "", tags)
        }) ?? nil
    }

    public func upsertAudioFeatures(_ rows: [AudioFeatureRow]) throws {
        guard !rows.isEmpty else { return }
        let iso = ISO8601DateFormatter().string(from: Date())
        let chunk = Self.rowsPerChunk(columns: 9)
        try pool.write { db in
            var start = 0
            while start < rows.count {
                let slice = rows[start..<min(start + chunk, rows.count)]
                let placeholders = slice.map { _ in "(?,?,?,?,?,?,?,?,?)" }.joined(separator: ",")
                var args: [DatabaseValueConvertible?] = []
                args.reserveCapacity(slice.count * 9)
                for r in slice {
                    args.append(contentsOf: [r.matchKey, r.bpm, r.camelot, r.keyRoot,
                                             r.keyMode, r.energy, r.duration, r.tags, iso] as [DatabaseValueConvertible?])
                }
                try db.execute(sql: """
                    INSERT INTO track_audio_features
                      (match_key, bpm, camelot, key_root, key_mode, energy, duration, tags, synced_at)
                    VALUES \(placeholders)
                    ON CONFLICT(match_key) DO UPDATE SET
                      bpm=excluded.bpm, camelot=excluded.camelot, key_root=excluded.key_root,
                      key_mode=excluded.key_mode, energy=excluded.energy, duration=excluded.duration,
                      tags=excluded.tags, synced_at=excluded.synced_at
                """, arguments: StatementArguments(args))
                start += chunk
            }
        }
    }

    public struct DJCandidate: Sendable {
        public var id: String
        public var title: String
        public var artist: String?
        public var album: String?
        public var bpm: Double
        public var camelot: String
        public var energy: Double
        public var tags: String?
        public var imageKey: String?
    }

    /// Tracks with audio features inside the BPM window (incl. half/double-time),
    /// optional tag filter, deduped by title+artist.
    public func djCandidates(minBPM: Double, maxBPM: Double, tags: [String], excludeLive: Bool) throws -> [DJCandidate] {
        try pool.read { db in
            var sql = """
                SELECT t.id, t.title, t.artist, t.album, t.image_key, f.bpm, f.camelot, f.energy, f.tags
                FROM tracks t JOIN track_audio_features f ON t.match_key = f.match_key
                WHERE f.bpm IS NOT NULL AND (
                      (f.bpm BETWEEN ? AND ?) OR (f.bpm/2.0 BETWEEN ? AND ?) OR (f.bpm*2.0 BETWEEN ? AND ?)
                )
            """
            var args: [DatabaseValueConvertible] = [minBPM, maxBPM, minBPM, maxBPM, minBPM, maxBPM]
            if excludeLive { sql += " AND t.is_live = 0" }
            if !tags.isEmpty {
                let clause = tags.map { _ in "LOWER(f.tags) LIKE ?" }.joined(separator: " OR ")
                sql += " AND (\(clause))"
                args.append(contentsOf: tags.map { "%\"\($0.lowercased())\"%" as DatabaseValueConvertible })
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            var seen = Set<String>()
            var result: [DJCandidate] = []
            for r in rows {
                let title = r["title"] as String? ?? ""
                let artist = r["artist"] as String?
                let dedup = "\(title.lowercased())|\((artist ?? "").lowercased())"
                guard !seen.contains(dedup) else { continue }
                seen.insert(dedup)
                result.append(DJCandidate(
                    id: r["id"] ?? "", title: title, artist: artist, album: r["album"],
                    bpm: r["bpm"] ?? 0, camelot: r["camelot"] ?? "", energy: r["energy"] ?? 0.5, tags: r["tags"],
                    imageKey: r["image_key"]
                ))
            }
            return result
        }
    }

    /// (features stored, tracks in the library that have a matching feature).
    public func audioFeaturesStats() throws -> (total: Int, matched: Int) {
        try pool.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_audio_features") ?? 0
            let matched = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tracks t JOIN track_audio_features f ON t.match_key = f.match_key
            """) ?? 0
            return (total, matched)
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
