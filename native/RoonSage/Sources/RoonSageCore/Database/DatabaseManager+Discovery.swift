import Foundation
import GRDB

extension DatabaseManager {
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

    /// All tracks of one album (by album_key), in sync/browse order, joined with
    /// audio features. Used by the album detail drill-down.
    public func tracksForAlbum(_ albumKey: String) throws -> [LibraryTrackRow] {
        try pool.read { db in
            let sql = """
                SELECT t.id, t.title, t.artist, t.album, t.year, t.is_live, t.image_key, f.bpm, f.camelot, f.tags
                FROM tracks t LEFT JOIN track_audio_features f ON t.match_key = f.match_key
                WHERE t.album_key = ?
                ORDER BY t.rowid
            """
            let rows = try Row.fetchAll(db, sql: sql,
                arguments: StatementArguments([albumKey] as [DatabaseValueConvertible]))
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

    /// Tracks (left-joined with audio features) filtered by free-text query and
    /// an optional tag. Returns title/artist/album + bpm/camelot/tags when known.
    public func browseTracks(query: String, tag: String?, limit: Int = 300) throws -> [LibraryTrackRow] {
        try pool.read { db in
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

}
