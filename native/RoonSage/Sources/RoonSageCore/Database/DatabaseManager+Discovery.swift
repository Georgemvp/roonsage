import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Discovery (cache-only sections)

    /// Albums with no matching entry in listening history — never played here.
    public func undiscoveredAlbums(limit: Int = 16) async throws ->[AlbumResult] {
        try await pool.read { db in
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

    /// Undiscovered albums (never in listening history) plus each album's analyzed
    /// `match_key`s, so the caller can rank them by how close their embedding centroid
    /// sits to the personal taste vector. A larger, randomly-sampled candidate pool than
    /// the final shelf — the caller re-ranks by taste and trims. The random sample keeps
    /// the pool varied run-to-run so "Herontdek" doesn't ossify into the same albums.
    public func undiscoveredAlbumCandidates(limit: Int = 80) async throws -> [(album: AlbumResult, matchKeys: [String])] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT album_key, album, artist, year, COUNT(*) AS track_count,
                       MAX(image_key) AS image_key, GROUP_CONCAT(match_key, '|') AS match_keys
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
            return rows.map { row in
                let mkRaw = (row["match_keys"] as String?) ?? ""
                let mks = mkRaw.split(separator: "|").map(String.init).filter { !$0.isEmpty }
                let album = AlbumResult(
                    albumKey:   row["album_key"]   as String? ?? "",
                    album:      row["album"]        as String? ?? "",
                    artist:     row["artist"],
                    year:       row["year"],
                    trackCount: row["track_count"]  as Int? ?? 0,
                    imageKey:   row["image_key"]
                )
                return (album: album, matchKeys: mks)
            }
        }
    }

    /// Tracks you used to play but haven't in the last `days` days, max 2 per
    /// artist, most-played first. Resolved to current library item_keys.
    public func forgottenFavorites(days: Int = 60, limit: Int = 20) async throws ->[TrackRecord] {
        try await pool.read { db in
            let cutoff = Self.isoFormatter.string(from: Date().addingTimeInterval(-Double(days) * 86_400))
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

    /// Owned albums you *used to* play but haven't in the last `days` days — the
    /// "rediscover old music" signal. Ranked by how much you played them (depth),
    /// **not** by taste-vector similarity, so this shelf doesn't converge on the
    /// same sonic centroid as the other Ontdek surfaces (that convergence is what
    /// made every discovery feature feel like the same list). Distinct from
    /// `undiscoveredAlbums` (never played at all): these are albums you loved and
    /// then forgot. Max 1 per artist so the shelf spans your history, not one artist.
    public func dormantAlbums(days: Int = 120, minPlays: Int = 3, limit: Int = 16) async throws -> [AlbumResult] {
        try await pool.read { db in
            let cutoff = Self.isoFormatter.string(from: Date().addingTimeInterval(-Double(days) * 86_400))
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.album_key, t.album, t.artist, t.year,
                       COUNT(DISTINCT t.id) AS track_count, MAX(t.image_key) AS image_key, h.plays AS plays
                FROM tracks t
                JOIN (
                    SELECT LOWER(album) AS alb, COUNT(*) AS plays, MAX(played_at) AS last_play
                    FROM listening_history
                    WHERE album IS NOT NULL AND album <> ''
                    GROUP BY LOWER(album)
                    HAVING last_play < ? AND plays >= ?
                ) h ON LOWER(t.album) = h.alb
                WHERE t.album IS NOT NULL AND t.album <> ''
                GROUP BY t.album_key
                HAVING track_count >= 3
                ORDER BY h.plays DESC
                LIMIT ?
            """, arguments: [cutoff, minPlays, limit * 4])
            var perArtist: [String: Int] = [:]
            var result: [AlbumResult] = []
            for row in rows {
                let aKey = ((row["artist"] as String?) ?? "").lowercased()
                if perArtist[aKey, default: 0] >= 1 { continue }
                perArtist[aKey, default: 0] += 1
                result.append(AlbumResult(
                    albumKey:   row["album_key"]  as String? ?? "",
                    album:      row["album"]      as String? ?? "",
                    artist:     row["artist"],
                    year:       row["year"],
                    trackCount: row["track_count"] as Int? ?? 0,
                    imageKey:   row["image_key"]))
                if result.count >= limit { break }
            }
            return result
        }
    }

    /// Per-album play aggregates for OWNED albums that appear in listening history,
    /// each with its most-recent play and total play count — the raw signal
    /// `ForgottenMusicService` scores by recency-decay. Album identity is the
    /// `LOWER(album)` string join (there is no album id in history). One row per
    /// `album_key`; albums with fewer than `minTracks` owned tracks are skipped
    /// (single-track "albums" are usually singles/compilation noise). Ordered
    /// least-recently-played first and bounded to `limit` so the scored pool stays
    /// cheap on a large history.
    public func playedAlbumAggregates(minTracks: Int = 3, limit: Int = 400) async throws
        -> [(album: AlbumResult, lastPlayedAt: Date?, playCount: Int)] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.album_key, t.album, t.artist, t.year,
                       COUNT(DISTINCT t.id) AS track_count, MAX(t.image_key) AS image_key,
                       h.plays AS plays, h.last_play AS last_play
                FROM tracks t
                JOIN (
                    SELECT LOWER(album) AS alb, COUNT(*) AS plays, MAX(played_at) AS last_play
                    FROM listening_history
                    WHERE album IS NOT NULL AND album <> ''
                    GROUP BY LOWER(album)
                ) h ON LOWER(t.album) = h.alb
                WHERE t.album IS NOT NULL AND t.album <> ''
                GROUP BY t.album_key
                HAVING track_count >= ?
                ORDER BY h.last_play ASC
                LIMIT ?
            """, arguments: [minTracks, limit])
            return rows.map { row in
                let album = AlbumResult(
                    albumKey:   row["album_key"]  as String? ?? "",
                    album:      row["album"]      as String? ?? "",
                    artist:     row["artist"],
                    year:       row["year"],
                    trackCount: row["track_count"] as Int? ?? 0,
                    imageKey:   row["image_key"])
                let last = (row["last_play"] as String?).flatMap { Self.isoFormatter.date(from: $0) }
                return (album: album, lastPlayedAt: last, playCount: row["plays"] as Int? ?? 0)
            }
        }
    }

    /// Your most-played tracks (from listening history), resolved to current
    /// library item_keys.
    public func topTracks(limit: Int = 25) async throws ->[TrackRecord] {
        try await pool.read { db in
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
        /// Content match key — joins play stats / features / lyrics; nil pre-resync.
        public var matchKey: String?
    }

    /// Dataset-level ordering for `browseTracks` (the LIMIT makes client-side
    /// re-sorting of the returned page meaningless for these).
    public enum BrowseOrder: Sendable {
        case artist          // the classic artist/year/title browse order
        case recentlyAdded   // newest first_seen first (track_first_seen side table)
        // Column sorts done in SQL so offset pagination stays consistent (a client-
        // side re-sort of one page would reshuffle across page boundaries).
        case title
        case album
        case year
        case bpm
    }

    /// All tracks of one album (by album_key), in sync/browse order, joined with
    /// audio features. Used by the album detail drill-down.
    public func tracksForAlbum(_ albumKey: String) async throws ->[LibraryTrackRow] {
        try await pool.read { db in
            let sql = """
                SELECT t.id, t.title, t.artist, t.album, t.year, t.is_live, t.image_key, t.match_key AS mk,
                       f.bpm, f.camelot, f.tags
                FROM tracks t LEFT JOIN track_audio_features f ON t.match_key = f.match_key
                WHERE t.album_key = ?
                ORDER BY t.rowid
            """
            let rows = try Row.fetchAll(db, sql: sql,
                arguments: StatementArguments([albumKey] as [DatabaseValueConvertible]))
            return rows.map { Self.libraryTrackRow($0) }
        }
    }

    /// Tracks (left-joined with audio features) filtered by free-text query and
    /// an optional tag. Returns title/artist/album + bpm/camelot/tags when known.
    public func browseTracks(query: String, tag: String?, limit: Int = 300,
                             order: BrowseOrder = .artist, offset: Int = 0) async throws ->[LibraryTrackRow] {
        try await pool.read { db in
            var conditions: [String] = []
            var args: [DatabaseValueConvertible] = []
            // FTS5 prefix match instead of a leading-wildcard LIKE full scan.
            if !query.isEmpty, let match = Self.ftsQuery(query) {
                conditions.append("t.rowid IN (SELECT rowid FROM tracks_fts WHERE tracks_fts MATCH ?)")
                args.append(match)
            }
            if let tag, !tag.isEmpty {
                conditions.append("LOWER(f.tags) LIKE ?")
                args.append("%\"\(tag.lowercased())\"%")
            }
            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let joinFirstSeen: String
            let orderClause: String
            switch order {
            case .artist:
                joinFirstSeen = ""
                orderClause = "ORDER BY t.artist, t.year, t.title"
            case .recentlyAdded:
                joinFirstSeen = "LEFT JOIN track_first_seen fs ON fs.match_key = t.match_key"
                // NULL first_seen (pre-migration rows not yet re-synced) sorts last.
                orderClause = "ORDER BY (fs.first_seen IS NULL), fs.first_seen DESC, t.rowid DESC"
            case .title:
                joinFirstSeen = ""
                orderClause = "ORDER BY t.title COLLATE NOCASE, t.artist, t.rowid"
            case .album:
                joinFirstSeen = ""
                orderClause = "ORDER BY t.album COLLATE NOCASE, t.year, t.title, t.rowid"
            case .year:
                joinFirstSeen = ""
                orderClause = "ORDER BY (t.year IS NULL), t.year, t.artist, t.title, t.rowid"
            case .bpm:
                joinFirstSeen = ""
                orderClause = "ORDER BY (f.bpm IS NULL), f.bpm, t.title, t.rowid"
            }
            let sql = """
                SELECT t.id, t.title, t.artist, t.album, t.year, t.is_live, t.image_key, t.match_key AS mk,
                       f.bpm, f.camelot, f.tags
                FROM tracks t LEFT JOIN track_audio_features f ON t.match_key = f.match_key
                \(joinFirstSeen)
                \(whereClause)
                \(orderClause) LIMIT ? OFFSET ?
            """
            args.append(limit)
            args.append(offset)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { Self.libraryTrackRow($0) }
        }
    }

    /// Rows for an explicit, pre-ranked match-key list (most/recently played:
    /// the ranking comes from play stats, the rows from here). Result follows
    /// the input order; keys without a library row are skipped. One library
    /// row per match key (a key can cover several editions).
    public func tracksByMatchKeys(_ orderedKeys: [String]) async throws -> [LibraryTrackRow] {
        guard !orderedKeys.isEmpty else { return [] }
        return try await pool.read { db in
            var byKey: [String: LibraryTrackRow] = [:]
            var start = 0
            while start < orderedKeys.count {
                let slice = Array(orderedKeys[start..<min(start + 500, orderedKeys.count)])
                let placeholders = slice.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT t.id, t.title, t.artist, t.album, t.year, t.is_live, t.image_key, t.match_key AS mk,
                           f.bpm, f.camelot, f.tags
                    FROM tracks t LEFT JOIN track_audio_features f ON t.match_key = f.match_key
                    WHERE t.match_key IN (\(placeholders))
                    """, arguments: StatementArguments(slice))
                for r in rows {
                    let row = Self.libraryTrackRow(r)
                    if let mk = row.matchKey, byKey[mk] == nil { byKey[mk] = row }
                }
                start += 500
            }
            return orderedKeys.compactMap { byKey[$0] }
        }
    }

    /// Shared row mapper for the browse queries (expects `mk` aliased match_key).
    private static func libraryTrackRow(_ r: Row) -> LibraryTrackRow {
        var tags: [String] = []
        if let t = r["tags"] as String?, let data = t.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            tags = arr.compactMap { $0 as? String }
        }
        return LibraryTrackRow(
            id: r["id"] ?? "", title: r["title"] ?? "", artist: r["artist"], album: r["album"],
            year: r["year"], isLive: (r["is_live"] as Bool?) ?? false,
            imageKey: r["image_key"],
            bpm: r["bpm"], camelot: r["camelot"], tags: tags,
            matchKey: r["mk"]
        )
    }

    /// Most common LLM tags (parsed from the JSON arrays), for filter chips.
    public func topTags(limit: Int = 30) async throws ->[(tag: String, count: Int)] {
        try await pool.read { db in
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

}
