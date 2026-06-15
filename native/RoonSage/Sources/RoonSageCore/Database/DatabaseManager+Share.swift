import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Library share (Mac → iPhone over ZeroTier)
    //
    // The Mac app exports its fully-synced library as JSON; the iOS app
    // imports it instead of doing the hours-long Browse walk on the phone.
    // Roon item_keys are session-scoped, so exported ids are useless on the
    // importing device — imported rows get synthetic `import::artist::title`
    // keys that BrowseService resolves via a fresh search at playback time
    // (the same convention as `qobuz_search::`).

    static let importKeyPrefix = "import::"

    /// The full library (tracks + genres) as a compact JSON document.
    public func exportLibraryJSON() async throws -> Data {
        try await pool.read { db in
            var genresByTrack: [String: [String]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT track_id, genre FROM track_genres") {
                if let id = row["track_id"] as String?, let g = row["genre"] as String? {
                    genresByTrack[id, default: []].append(g)
                }
            }
            var tracks: [[String: Any]] = []
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, title, artist, album, album_key, year, is_live, match_key, image_key, album_fp
                FROM tracks
            """)
            tracks.reserveCapacity(rows.count)
            for r in rows {
                var o: [String: Any] = ["t": r["title"] as String? ?? ""]
                if let v = r["artist"] as String? { o["a"] = v }
                if let v = r["album"] as String? { o["al"] = v }
                if let v = r["year"] as Int? { o["y"] = v }
                if (r["is_live"] as Bool? ?? false) { o["l"] = 1 }
                if let v = r["match_key"] as String? { o["mk"] = v }
                if let v = r["image_key"] as String? { o["ik"] = v }
                // Album fingerprint groups tracks into albums on the importing
                // device (COUNT(DISTINCT album_key), undiscovered albums…).
                // Older libraries synced before album_fp existed have it NULL —
                // fall back to album|artist so the importer still gets a stable,
                // non-null album key (otherwise "0 albums").
                if let v = r["album_fp"] as String?, !v.isEmpty {
                    o["fp"] = v
                } else if let al = r["album"] as String?, !al.isEmpty {
                    o["fp"] = al + "|" + (r["artist"] as String? ?? "")
                }
                if let id = r["id"] as String?, let g = genresByTrack[id], !g.isEmpty { o["g"] = g }
                tracks.append(o)
            }
            return try JSONSerialization.data(withJSONObject: ["version": 1, "tracks": tracks])
        }
    }

    /// Replace the whole library with an exported document. Returns the number
    /// of imported tracks. Clears any interrupted-sync state: after an import
    /// the library is complete by definition.
    public func importLibrary(json: Data) async throws -> Int {
        guard let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let items = obj["tracks"] as? [[String: Any]] else {
            throw ImportError.malformed
        }

        var records: [TrackRecord] = []
        var fps: [String?] = []
        var genrePairs: [(String, String)] = []
        records.reserveCapacity(items.count)
        for (i, o) in items.enumerated() {
            guard let title = o["t"] as? String, !title.isEmpty else { continue }
            let artist = o["a"] as? String
            // Synthetic playback key (index suffix keeps the PK unique for
            // duplicate title+artist across albums).
            let id = Self.importKeyPrefix
                + Self.encodeKeyPart(artist ?? "") + "::"
                + Self.encodeKeyPart(title) + "::\(i)"
            let album = o["al"] as? String
            // The Mac's Roon item_key album_key is session-scoped and useless on
            // the phone, so it isn't exported. But album grouping (library stats,
            // undiscovered albums, playAlbum's local WHERE album_key=? filter)
            // needs a stable per-album id. Reuse the exported album fingerprint
            // ("fp"); without it COUNT(DISTINCT album_key) is 0 and every album
            // collapses into one GROUP BY bucket. Fall back to album|artist for
            // older exports that predate the fingerprint.
            let albumKey = (o["fp"] as? String)
                ?? album.map { $0 + "|" + (artist ?? "") }
            records.append(TrackRecord(
                id: id,
                title: title,
                artist: artist,
                album: album,
                albumKey: albumKey,
                year: o["y"] as? Int,
                isLive: (o["l"] as? Int ?? 0) == 1,
                matchKey: o["mk"] as? String,
                imageKey: o["ik"] as? String
            ))
            fps.append(o["fp"] as? String)
            if let genres = o["g"] as? [String] {
                for g in genres { genrePairs.append((id, g)) }
            }
        }
        guard !records.isEmpty else { throw ImportError.empty }

        try await pool.write { db in
            try db.execute(sql: "DELETE FROM tracks")
            try db.execute(sql: "DELETE FROM sync_album_checkpoints")

            let chunk = Self.rowsPerChunk(columns: 10)
            var start = 0
            while start < records.count {
                let end = min(start + chunk, records.count)
                let slice = records[start..<end]
                let placeholders = slice.map { _ in "(?,?,?,?,?,?,?,?,?,?)" }.joined(separator: ",")
                var args: [DatabaseValueConvertible?] = []
                args.reserveCapacity(slice.count * 10)
                for (offset, r) in slice.enumerated() {
                    args.append(contentsOf: [r.id, r.title, r.artist, r.album, r.albumKey,
                                             r.year, r.isLive, r.matchKey, r.imageKey,
                                             fps[start + offset]] as [DatabaseValueConvertible?])
                }
                try db.execute(sql: """
                    INSERT INTO tracks
                      (id, title, artist, album, album_key, year, is_live, match_key, image_key, album_fp)
                    VALUES \(placeholders)
                """, arguments: StatementArguments(args))
                start = end
            }

            // Genres (cascade-cleared with the tracks delete).
            let gChunk = Self.rowsPerChunk(columns: 2)
            var gStart = 0
            while gStart < genrePairs.count {
                let slice = genrePairs[gStart..<min(gStart + gChunk, genrePairs.count)]
                let placeholders = slice.map { _ in "(?,?)" }.joined(separator: ",")
                var args: [DatabaseValueConvertible] = []
                for p in slice { args.append(p.0); args.append(p.1) }
                try db.execute(
                    sql: "INSERT OR IGNORE INTO track_genres (track_id, genre) VALUES \(placeholders)",
                    arguments: StatementArguments(args))
                gStart += slice.count
            }

            try db.execute(sql: """
                INSERT INTO sync_state (key, value) VALUES ('sync_in_progress','0')
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """)
            try db.execute(sql: """
                INSERT INTO sync_state (key, value) VALUES ('last_sync', ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """, arguments: [Self.isoFormatter.string(from: Date())])
        }
        return records.count
    }

    static func encodeKeyPart(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    public enum ImportError: LocalizedError {
        case malformed, empty
        public var errorDescription: String? {
            switch self {
            case .malformed: "Onbruikbaar exportbestand (geen tracks-array)."
            case .empty:     "Export bevat geen tracks."
            }
        }
    }
}
