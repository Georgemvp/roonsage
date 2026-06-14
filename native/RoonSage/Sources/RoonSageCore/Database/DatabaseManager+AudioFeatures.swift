import AudioAnalysis
import Foundation
import GRDB

extension DatabaseManager {
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
        public var moods: String?     // JSON {"happy":0.4,…}, from the analyzer
        public init(matchKey: String, bpm: Double?, camelot: String?, keyRoot: String?,
                    keyMode: String?, energy: Double?, duration: Double?, tags: String?,
                    moods: String? = nil) {
            self.matchKey = matchKey; self.bpm = bpm; self.camelot = camelot; self.keyRoot = keyRoot
            self.keyMode = keyMode; self.energy = energy; self.duration = duration; self.tags = tags
            self.moods = moods
        }
    }

    /// Decode a packed little-endian Float32 BLOB (CLAP embedding) to [Float].
    static func floatsFromBlob(_ d: Data) -> [Float] {
        d.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
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
        let iso = Self.isoFormatter.string(from: Date())
        let chunk = Self.rowsPerChunk(columns: 10)
        try pool.write { db in
            var start = 0
            while start < rows.count {
                let slice = rows[start..<min(start + chunk, rows.count)]
                let placeholders = slice.map { _ in "(?,?,?,?,?,?,?,?,?,?)" }.joined(separator: ",")
                var args: [DatabaseValueConvertible?] = []
                args.reserveCapacity(slice.count * 10)
                for r in slice {
                    args.append(contentsOf: [r.matchKey, r.bpm, r.camelot, r.keyRoot,
                                             r.keyMode, r.energy, r.duration, r.tags, r.moods, iso] as [DatabaseValueConvertible?])
                }
                try db.execute(sql: """
                    INSERT INTO track_audio_features
                      (match_key, bpm, camelot, key_root, key_mode, energy, duration, tags, moods, synced_at)
                    VALUES \(placeholders)
                    ON CONFLICT(match_key) DO UPDATE SET
                      bpm=excluded.bpm, camelot=excluded.camelot, key_root=excluded.key_root,
                      key_mode=excluded.key_mode, energy=excluded.energy, duration=excluded.duration,
                      tags=excluded.tags, moods=excluded.moods, synced_at=excluded.synced_at
                """, arguments: StatementArguments(args))
                start += chunk
            }
        }
    }

    /// Apply the analyzer's binary `/embeddings` bundle (RSEB format):
    ///   "RSEB" | ver:UInt8=1 | dim:UInt32LE | count:UInt32LE
    ///   then count × ( keyLen:UInt16LE | key:UTF8 | dim×Float32LE )
    /// Updates `embedding` on existing feature rows by match_key. Returns the
    /// number of rows updated.
    @discardableResult
    public func applyEmbeddingsBlob(_ data: Data) throws -> Int {
        let bytes = [UInt8](data)
        guard bytes.count >= 13, bytes[0] == 0x52, bytes[1] == 0x53, bytes[2] == 0x45, bytes[3] == 0x42,
              bytes[4] == 1 else { return 0 }   // "RSEB" v1
        func u16(_ o: Int) -> Int { Int(bytes[o]) | (Int(bytes[o + 1]) << 8) }
        func u32(_ o: Int) -> Int { Int(bytes[o]) | (Int(bytes[o + 1]) << 8) | (Int(bytes[o + 2]) << 16) | (Int(bytes[o + 3]) << 24) }
        let dim = u32(5)
        let count = u32(9)
        guard dim > 0, dim < 65536 else { return 0 }
        let vecBytes = dim * 4

        var pairs: [(key: String, blob: Data)] = []
        pairs.reserveCapacity(count)
        var o = 13
        for _ in 0..<count {
            guard o + 2 <= bytes.count else { break }
            let kl = u16(o); o += 2
            guard o + kl + vecBytes <= bytes.count else { break }
            let key = String(decoding: bytes[o..<o + kl], as: UTF8.self); o += kl
            let blob = data.subdata(in: o..<o + vecBytes); o += vecBytes
            pairs.append((key, blob))
        }

        var updated = 0
        try pool.write { db in
            for p in pairs {
                try db.execute(sql: "UPDATE track_audio_features SET embedding = ? WHERE match_key = ?",
                               arguments: [p.blob, p.key])
                updated += db.changesCount
            }
        }
        return updated
    }

    /// Persist the PCA-2D Music Map coordinates (Track E5d) by match_key.
    public func updateMapCoords(_ coords: [(matchKey: String, x: Double, y: Double)]) throws {
        guard !coords.isEmpty else { return }
        try pool.write { db in
            for c in coords {
                try db.execute(sql: "UPDATE track_audio_features SET map_x = ?, map_y = ? WHERE match_key = ?",
                               arguments: [c.x, c.y, c.matchKey])
            }
        }
    }

    // MARK: - Feature-match reconciliation (exact + fuzzy fallback / diagnostics)

    /// Identity (match_key + raw artist/title) of one analyzer feature row, as
    /// delivered by the `/features` payload. Carries artist/title so the fuzzy
    /// fallback and the diagnostic can compare against the library.
    public struct FeatureIdentity: Sendable {
        public var matchKey: String
        public var artist: String?
        public var title: String?
        public init(matchKey: String, artist: String?, title: String?) {
            self.matchKey = matchKey; self.artist = artist; self.title = title
        }
    }

    public struct AudioFeatureDiagnostic: Sendable {
        public var libraryTracks: Int       // tracks in the library
        public var featureRows: Int          // feature rows received from the analyzer
        public var exactMatched: Int         // library tracks joined by exact match_key
        public var fuzzyMatched: Int         // additionally resolved by the fuzzy fallback
        public var unmatched: Int            // library tracks still without features
        public var sampleUnmatched: [String] // up to 30 "artist — title" examples
        public var matchRate: Double {
            libraryTracks == 0 ? 0 : Double(exactMatched + fuzzyMatched) / Double(libraryTracks)
        }
    }

    /// Minimum token-containment score to accept a fuzzy title match.
    private static let fuzzyTitleThreshold = 0.85

    /// Reconcile library tracks against analyzer feature rows. Counts exact
    /// match_key joins, then for the remainder runs a fuzzy title match *within
    /// the same primary artist*. When `apply` is true, a confident fuzzy match
    /// rewrites `tracks.match_key` to the feature's key so the existing joins
    /// (`djCandidates`/`sonicTracks`) pick it up with no query change. When
    /// false it only measures (read-only diagnostic).
    public func reconcileFeatureMatches(_ feats: [FeatureIdentity], apply: Bool) throws -> AudioFeatureDiagnostic {
        // Bucket features by normalised primary artist, precomputing title tokens
        // so the inner loop is set intersections, not re-tokenisation.
        struct Cand { let matchKey: String; let tokens: Set<String> }
        var buckets: [String: [Cand]] = [:]
        for f in feats {
            let artistKey = TrackIdentity.normalise(TrackIdentity.primaryArtist(f.artist))
            buckets[artistKey, default: []].append(Cand(matchKey: f.matchKey, tokens: FuzzyMatch.tokens(f.title)))
        }

        return try pool.write { db in
            let libraryTracks = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") ?? 0
            let exact = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tracks t JOIN track_audio_features f ON t.match_key = f.match_key
            """) ?? 0

            // Library tracks with no exact feature match — fuzzy-fallback candidates.
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id, t.artist, t.title FROM tracks t
                LEFT JOIN track_audio_features f ON t.match_key = f.match_key
                WHERE f.match_key IS NULL
            """)

            var fuzzy = 0
            var sample: [String] = []
            var links: [(String, String)] = []   // (trackID, featureMatchKey)

            for r in rows {
                let artist = r["artist"] as String?
                let title = r["title"] as String?
                let artistKey = TrackIdentity.normalise(TrackIdentity.primaryArtist(artist))
                let titleTokens = FuzzyMatch.tokens(title)
                var best = Self.fuzzyTitleThreshold
                var bestKey: String?
                for cand in buckets[artistKey] ?? [] {
                    let s = FuzzyMatch.score(titleTokens, cand.tokens)
                    if s >= best { best = s; bestKey = cand.matchKey }
                }
                if let key = bestKey {
                    fuzzy += 1
                    if apply, let id = r["id"] as String? { links.append((id, key)) }
                } else if sample.count < 30 {
                    sample.append("\(artist ?? "?") — \(title ?? "?")")
                }
            }

            if apply, !links.isEmpty {
                for (id, key) in links {
                    try db.execute(sql: "UPDATE tracks SET match_key = ? WHERE id = ?", arguments: [key, id])
                }
            }

            return AudioFeatureDiagnostic(
                libraryTracks: libraryTracks, featureRows: feats.count,
                exactMatched: exact, fuzzyMatched: fuzzy,
                unmatched: rows.count - fuzzy, sampleUnmatched: sample
            )
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

    public struct SonicTrack: Sendable, Identifiable {
        public var id: String
        public var title: String
        public var artist: String?
        public var album: String?
        public var imageKey: String?
        public var matchKey: String
        public var bpm: Double?
        public var camelot: String
        public var energy: Double?
        public var tags: [String]
        public var embedding: [Float]?       // 512-dim CLAP vector (Track E5)
        public var moods: [String: Float]    // mood → cosine, for Map colouring
        public var mapX: Double?             // PCA-2D projection (Music Map)
        public var mapY: Double?

        public init(id: String, title: String, artist: String?, album: String?, imageKey: String?,
                    matchKey: String, bpm: Double?, camelot: String, energy: Double?, tags: [String],
                    embedding: [Float]? = nil, moods: [String: Float] = [:],
                    mapX: Double? = nil, mapY: Double? = nil) {
            self.id = id; self.title = title; self.artist = artist; self.album = album
            self.imageKey = imageKey; self.matchKey = matchKey; self.bpm = bpm; self.camelot = camelot
            self.energy = energy; self.tags = tags; self.embedding = embedding; self.moods = moods
            self.mapX = mapX; self.mapY = mapY
        }
    }

    /// Every library track that has analyzed audio features, deduped by
    /// title+artist. Source data for Sonic Radio / Fingerprint / Music Map.
    public func sonicTracks(excludeLive: Bool = true) throws -> [SonicTrack] {
        try pool.read { db in
            var sql = """
                SELECT t.id, t.title, t.artist, t.album, t.image_key, t.match_key,
                       f.bpm, f.camelot, f.energy, f.tags, f.embedding, f.moods, f.map_x, f.map_y
                FROM tracks t JOIN track_audio_features f ON t.match_key = f.match_key
                WHERE f.match_key IS NOT NULL
            """
            if excludeLive { sql += " AND t.is_live = 0" }
            let rows = try Row.fetchAll(db, sql: sql)
            var seen = Set<String>()
            var out: [SonicTrack] = []
            out.reserveCapacity(rows.count)
            for r in rows {
                let title = r["title"] as String? ?? ""
                let artist = r["artist"] as String?
                let dedup = "\(title.lowercased())|\((artist ?? "").lowercased())"
                guard !seen.contains(dedup) else { continue }
                seen.insert(dedup)
                var tags: [String] = []
                if let t = r["tags"] as String?, let d = t.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: d) as? [Any] {
                    tags = arr.compactMap { ($0 as? String)?.lowercased() }
                }
                let embedding = (r["embedding"] as Data?).map(Self.floatsFromBlob)
                var moods: [String: Float] = [:]
                if let m = r["moods"] as String?, let d = m.data(using: .utf8) {
                    moods = (try? JSONDecoder().decode([String: Float].self, from: d)) ?? [:]
                }
                out.append(SonicTrack(
                    id: r["id"] ?? "", title: title, artist: artist, album: r["album"],
                    imageKey: r["image_key"], matchKey: r["match_key"] ?? "",
                    bpm: r["bpm"], camelot: r["camelot"] ?? "", energy: r["energy"], tags: tags,
                    embedding: embedding, moods: moods, mapX: r["map_x"], mapY: r["map_y"]
                ))
            }
            return out
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
