import Foundation
import GRDB

extension DatabaseManager {
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

    public func filterTracks(options: FilterOptions) async throws ->[TrackRecord] {
        try await pool.read { db in
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
            if !options.keywords.isEmpty, let match = Self.ftsQuery(options.keywords) {
                // FTS5 prefix match per keyword token (AND-combined) — replaces
                // a leading-wildcard LIKE that scanned the whole table.
                conditions.append("t.rowid IN (SELECT rowid FROM tracks_fts WHERE tracks_fts MATCH ?)")
                args.append(match)
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

    public struct PlaylistSummary: Sendable, Codable {
        public var id: Int64
        public var name: String
        public var trackCount: Int
        public var createdAt: String
    }

    public func savePlaylist(name: String, tracks: [TrackRecord]) async throws ->Int64 {
        try await pool.write { db in
            let iso = Self.isoFormatter.string(from: Date())
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

    /// A playlist imported from an external source (e.g. ListenBrainz). `externalID`
    /// is a stable, source-scoped key ("listenbrainz:<mbid>") used for idempotent sync.
    public struct ExternalPlaylist: Sendable {
        public var externalID: String
        public var name: String
        public var tracks: [TrackRecord]
        public init(externalID: String, name: String, tracks: [TrackRecord]) {
            self.externalID = externalID
            self.name = name
            self.tracks = tracks
        }
    }

    /// Reconcile the set of playlists imported from a given source against the
    /// freshly-fetched `playlists`, all in one transaction:
    ///   • playlists no longer present upstream are removed,
    ///   • existing ones are replaced (refreshing their tracks),
    ///   • new ones are inserted.
    /// `sourcePrefix` scopes the reconcile (e.g. "listenbrainz:") so playlists from
    /// other sources — and user-curated ones (NULL external_id) — are left untouched.
    public func syncExternalPlaylists(sourcePrefix: String, playlists: [ExternalPlaylist]) async throws {
        try await pool.write { db in
            let iso = Self.isoFormatter.string(from: Date())
            let keep = playlists.map { $0.externalID }

            // Prune playlists from this source that are no longer upstream. Deleting
            // the playlist row cascades to its playlist_tracks.
            if keep.isEmpty {
                try db.execute(
                    sql: "DELETE FROM playlists WHERE external_id LIKE ?",
                    arguments: ["\(sourcePrefix)%"]
                )
            } else {
                let ph = keep.map { _ in "?" }.joined(separator: ",")
                var args: [DatabaseValueConvertible] = ["\(sourcePrefix)%"]
                args.append(contentsOf: keep as [DatabaseValueConvertible])
                try db.execute(
                    sql: "DELETE FROM playlists WHERE external_id LIKE ? AND external_id NOT IN (\(ph))",
                    arguments: StatementArguments(args)
                )
            }

            let chunk = Self.rowsPerChunk(columns: 9)
            for pl in playlists {
                // Replace in place: drop the existing copy (cascades its tracks),
                // then re-insert so renamed/reordered upstream playlists stay in sync.
                try db.execute(sql: "DELETE FROM playlists WHERE external_id = ?", arguments: [pl.externalID])
                try db.execute(
                    sql: "INSERT INTO playlists (name, created_at, external_id) VALUES (?, ?, ?)",
                    arguments: [pl.name, iso, pl.externalID]
                )
                let pid = db.lastInsertedRowID
                var start = 0
                while start < pl.tracks.count {
                    let end = min(start + chunk, pl.tracks.count)
                    let placeholders = (start..<end).map { _ in "(?,?,?,?,?,?,?,?,?)" }.joined(separator: ",")
                    var args: [DatabaseValueConvertible?] = []
                    args.reserveCapacity((end - start) * 9)
                    for i in start..<end {
                        let t = pl.tracks[i]
                        args.append(contentsOf: [pid, i, t.id, t.title, t.artist, t.album, t.albumKey, t.year, t.isLive] as [DatabaseValueConvertible?])
                    }
                    try db.execute(sql: """
                        INSERT INTO playlist_tracks
                          (playlist_id, position, track_id, title, artist, album, album_key, year, is_live)
                        VALUES \(placeholders)
                    """, arguments: StatementArguments(args))
                    start += chunk
                }
            }
        }
    }

    public func listPlaylists() async throws ->[PlaylistSummary] {
        try await pool.read { db in
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
    public func playlistTracks(id: Int64) async throws ->[TrackRecord] {
        try await pool.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT track_id AS id, title, artist, album, album_key, year, is_live
                FROM playlist_tracks WHERE playlist_id = ? ORDER BY position
            """, arguments: [id])
        }
    }

    public func deletePlaylist(id: Int64) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM playlists WHERE id = ?", arguments: [id])
        }
    }

    /// Re-resolve a saved track to a CURRENT library track (Roon item_keys change
    /// across resyncs). Matches by title + artist, case-insensitive. Drops tracks
    /// that aren't in the library — use `resolveCurrentTracksAligned` when callers
    /// need to know which ones missed (e.g. to fall back to Qobuz).
    public func resolveCurrentTracks(_ saved: [TrackRecord]) async throws ->[TrackRecord] {
        try await resolveCurrentTracksAligned(saved).compactMap { $0 }
    }

    /// Like `resolveCurrentTracks`, but returns one element per input track
    /// (preserving order): the current-library match, or `nil` when the track
    /// isn't in the library. Lets playback fall back to Qobuz for the misses.
    public func resolveCurrentTracksAligned(_ saved: [TrackRecord]) async throws ->[TrackRecord?] {
        guard !saved.isEmpty else { return [] }
        return try await pool.read { db in
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
            return saved.map { s in
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

}
