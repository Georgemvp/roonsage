import AudioAnalysis
import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Audio features (synced from the native analyzer)

    public struct AudioFeatureRow: Sendable {
        public var matchKey: String
        public var bpm: Double?
        public var bpmConfidence: Double?
        public var camelot: String?
        public var keyRoot: String?
        public var keyMode: String?
        public var energy: Double?
        public var duration: Double?
        public var tags: String?
        public var moods: String?     // JSON {"happy":0.4,…}, from the analyzer
        public var attributes: String? // JSON {"valence":0.6,…}, from the analyzer
        public var popularity: Int?   // Deezer global rank (~0…1_000_000), from the analyzer
        public var loudness: Double?  // K-weighted LUFS (BS.1770), from the analyzer
        public var isrc: String?          // hard cross-source identity, from the dataset import
        public var recordingMbid: String? // canonical MusicBrainz recording, from the dataset import
        public var deezerBpm: Double?     // secondary tempo reference, from the dataset import
        public var albumUpc: String?      // hard cross-source ALBUM identity, from the dataset import
        public var label: String?         // record label, from the dataset import
        public var releaseDate: String?   // precise release date (YYYY-MM-DD), from the dataset import
        public var explicit: Bool?        // explicit-lyrics flag, from the dataset import
        /// Tag PROVENANCE: `clap-zs-*` for CLAP zero-shot tags, nil for the
        /// superseded Ollama metadata-guesser. Without this the two are
        /// indistinguishable downstream and guessed tags pollute sonic scoring.
        public var tagsModel: String?
        public init(matchKey: String, bpm: Double?, camelot: String?, keyRoot: String?,
                    keyMode: String?, energy: Double?, duration: Double?, tags: String?,
                    moods: String? = nil, bpmConfidence: Double? = nil, attributes: String? = nil,
                    popularity: Int? = nil, loudness: Double? = nil,
                    isrc: String? = nil, recordingMbid: String? = nil, deezerBpm: Double? = nil,
                    albumUpc: String? = nil, label: String? = nil, releaseDate: String? = nil,
                    explicit: Bool? = nil, tagsModel: String? = nil) {
            self.matchKey = matchKey; self.bpm = bpm; self.camelot = camelot; self.keyRoot = keyRoot
            self.keyMode = keyMode; self.energy = energy; self.duration = duration; self.tags = tags
            self.moods = moods; self.bpmConfidence = bpmConfidence; self.attributes = attributes
            self.popularity = popularity; self.loudness = loudness
            self.isrc = isrc; self.recordingMbid = recordingMbid; self.deezerBpm = deezerBpm
            self.albumUpc = albumUpc; self.label = label; self.releaseDate = releaseDate; self.explicit = explicit
            self.tagsModel = tagsModel
        }
    }

    /// Decode a packed little-endian Float32 BLOB (CLAP embedding) to [Float].
    static func floatsFromBlob(_ d: Data) -> [Float] {
        d.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
    }

    /// Audio features for one track by its content match key (for Now Playing).
    /// `async` on purpose: callers run on the MainActor, and a synchronous
    /// `pool.read` here blocks the UI thread (it stalls behind any in-flight
    /// import `pool.write`) — the recurring Now Playing freeze.
    public func featuresForMatchKey(_ matchKey: String) async -> (bpm: Double, camelot: String, tags: [String])? {
        (try? await pool.read { db -> (Double, String, [String])? in
            guard let r = try Row.fetchOne(db, sql: "SELECT bpm, camelot, tags FROM track_audio_features WHERE match_key = ?", arguments: [matchKey]) else { return nil }
            var tags: [String] = []
            if let t = r["tags"] as String?, let d = t.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: d) as? [Any] { tags = arr.compactMap { $0 as? String } }
            return (r["bpm"] ?? 0, r["camelot"] ?? "", tags)
        }) ?? nil
    }

    /// A similarity *seed* built straight from one audio-feature row — no join
    /// to `tracks`. Lets Sonic Radio seed from a now-playing track that the
    /// joined `sonicTracks()` library can't see: a streaming/Qobuz track that
    /// isn't in the library, an `is_live` row, or one whose library `match_key`
    /// diverges from the analyzer's. The synthesized track has no real id/title
    /// (id = match_key); callers must drive the engine off its features /
    /// embedding rather than its identity. nil when no feature row carries this
    /// match key.
    public func sonicSeed(matchKey: String) async -> SonicTrack? {
        guard !matchKey.isEmpty else { return nil }
        return (try? await pool.read { db -> SonicTrack? in
            guard let r = try Row.fetchOne(db, sql: """
                SELECT bpm, camelot, energy, tags, tags_model, loudness, embedding, moods, attributes
                FROM track_audio_features WHERE match_key = ?
                """, arguments: [matchKey]) else { return nil }
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
            // Attributes carry `arousal` — without them the seed of every radio
            // silently degrades to raw RMS energy.
            var attributes: [String: Float] = [:]
            if let a = r["attributes"] as String?, let d = a.data(using: .utf8) {
                attributes = (try? JSONDecoder().decode([String: Float].self, from: d)) ?? [:]
            }
            return SonicTrack(
                id: matchKey, title: "", artist: nil, album: nil, imageKey: nil,
                matchKey: matchKey, bpm: r["bpm"], camelot: r["camelot"] ?? "",
                rmsEnergy: r["energy"], tags: tags, embedding: embedding, moods: moods,
                attributes: attributes, loudness: r["loudness"],
                tagsAreCLAP: (r["tags_model"] as String?)?.isEmpty == false)
        }) ?? nil
    }

    /// The full feature row for one track — feeds the track-info sheet.
    public func audioFeatureRow(matchKey: String) async -> AudioFeatureRow? {
        guard !matchKey.isEmpty else { return nil }
        return (try? await pool.read { db -> AudioFeatureRow? in
            guard let r = try Row.fetchOne(db, sql: """
                SELECT bpm, bpm_confidence, camelot, key_root, key_mode, energy, duration,
                       tags, moods, attributes, popularity, loudness, isrc, recording_mbid,
                       album_upc, label, release_date, explicit
                FROM track_audio_features WHERE match_key = ?
                """, arguments: [matchKey]) else { return nil }
            return AudioFeatureRow(
                matchKey: matchKey, bpm: r["bpm"], camelot: r["camelot"], keyRoot: r["key_root"],
                keyMode: r["key_mode"], energy: r["energy"], duration: r["duration"],
                tags: r["tags"], moods: r["moods"], bpmConfidence: r["bpm_confidence"],
                attributes: r["attributes"], popularity: r["popularity"], loudness: r["loudness"],
                isrc: r["isrc"], recordingMbid: r["recording_mbid"],
                albumUpc: r["album_upc"], label: r["label"], releaseDate: r["release_date"],
                explicit: (r["explicit"] as Int?).map { $0 != 0 })
        }) ?? nil
    }

    /// CLAP attribute scores for one track by content match key (for Now Playing).
    /// `async` on purpose — see `featuresForMatchKey`: a synchronous MainActor
    /// read here is the per-second Now Playing freeze.
    public func attributesForMatchKey(_ matchKey: String) async -> [String: Float] {
        (try? await pool.read { db -> [String: Float] in
            guard let s = try String.fetchOne(
                db, sql: "SELECT attributes FROM track_audio_features WHERE match_key = ?", arguments: [matchKey]),
                let d = s.data(using: .utf8) else { return [:] }
            return (try? JSONDecoder().decode([String: Float].self, from: d)) ?? [:]
        }) ?? [:]
    }

    /// LUFS per match key (only measured rows) — feeds local loudness
    /// normalization when building a playback queue.
    public func loudnessByMatchKey(_ keys: [String]) async -> [String: Double] {
        guard !keys.isEmpty else { return [:] }
        return (try? await pool.read { db -> [String: Double] in
            var out: [String: Double] = [:]
            var start = 0
            while start < keys.count {
                let slice = Array(keys[start..<min(start + 500, keys.count)])
                let placeholders = slice.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT match_key, loudness FROM track_audio_features
                    WHERE loudness IS NOT NULL AND match_key IN (\(placeholders))
                    """, arguments: StatementArguments(slice))
                for r in rows { out[r["match_key"]] = r["loudness"] }
                start += 500
            }
            return out
        }) ?? [:]
    }

    /// Mean LUFS per album (join tracks→features on match_key) — the reference
    /// for album-mode loudness normalization, preserving intra-album dynamics.
    public func albumMeanLoudness(albums: [String]) async -> [String: Double] {
        let names = albums.filter { !$0.isEmpty }
        guard !names.isEmpty else { return [:] }
        return (try? await pool.read { db -> [String: Double] in
            var out: [String: Double] = [:]
            var start = 0
            while start < names.count {
                let slice = Array(names[start..<min(start + 500, names.count)])
                let placeholders = slice.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT t.album AS album, AVG(f.loudness) AS lufs
                    FROM tracks t
                    JOIN track_audio_features f ON f.match_key = t.match_key
                    WHERE f.loudness IS NOT NULL AND t.album IN (\(placeholders))
                    GROUP BY t.album
                    """, arguments: StatementArguments(slice))
                for r in rows { out[r["album"]] = r["lufs"] }
                start += 500
            }
            return out
        }) ?? [:]
    }

    public func upsertAudioFeatures(_ rows: [AudioFeatureRow]) async throws {
        guard !rows.isEmpty else { return }
        let iso = Self.isoFormatter.string(from: Date())
        let chunk = Self.rowsPerChunk(columns: 22)
        try await pool.write { db in
            var start = 0
            while start < rows.count {
                let slice = rows[start..<min(start + chunk, rows.count)]
                let placeholders = slice.map { _ in "(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)" }.joined(separator: ",")
                var args: [DatabaseValueConvertible?] = []
                args.reserveCapacity(slice.count * 22)
                for r in slice {
                    args.append(contentsOf: [r.matchKey, r.bpm, r.camelot, r.keyRoot,
                                             r.keyMode, r.energy, r.duration, r.tags, r.moods,
                                             r.bpmConfidence, r.attributes, r.popularity, r.loudness,
                                             r.isrc, r.recordingMbid, r.deezerBpm,
                                             r.albumUpc, r.label, r.releaseDate, r.explicit.map { $0 ? 1 : 0 },
                                             r.tagsModel, iso] as [DatabaseValueConvertible?])
                }
                try db.execute(sql: """
                    INSERT INTO track_audio_features
                      (match_key, bpm, camelot, key_root, key_mode, energy, duration, tags, moods, bpm_confidence, attributes, popularity, loudness, isrc, recording_mbid, deezer_bpm, album_upc, label, release_date, explicit, tags_model, synced_at)
                    VALUES \(placeholders)
                    ON CONFLICT(match_key) DO UPDATE SET
                      bpm=excluded.bpm, camelot=excluded.camelot, key_root=excluded.key_root,
                      key_mode=excluded.key_mode, energy=excluded.energy, duration=excluded.duration,
                      tags=excluded.tags, moods=excluded.moods, bpm_confidence=excluded.bpm_confidence,
                      -- NOT coalesced: provenance must always describe the tags it
                      -- ships with, or a stale `clap-zs` stamp would vouch for
                      -- replaced tags.
                      tags_model=excluded.tags_model,
                      attributes=excluded.attributes,
                      popularity=COALESCE(excluded.popularity, track_audio_features.popularity),
                      loudness=COALESCE(excluded.loudness, track_audio_features.loudness),
                      isrc=COALESCE(excluded.isrc, track_audio_features.isrc),
                      recording_mbid=COALESCE(excluded.recording_mbid, track_audio_features.recording_mbid),
                      deezer_bpm=COALESCE(excluded.deezer_bpm, track_audio_features.deezer_bpm),
                      album_upc=COALESCE(excluded.album_upc, track_audio_features.album_upc),
                      label=COALESCE(excluded.label, track_audio_features.label),
                      release_date=COALESCE(excluded.release_date, track_audio_features.release_date),
                      explicit=COALESCE(excluded.explicit, track_audio_features.explicit),
                      synced_at=excluded.synced_at
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
    public func applyEmbeddingsBlob(_ data: Data) async throws -> Int {
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

        // Immutable copy + count returned from the closure: the async pool.write
        // closure is @Sendable and may not capture/mutate outer vars.
        let outPairs = pairs
        return try await pool.write { db -> Int in
            var updated = 0
            for p in outPairs {
                try db.execute(sql: "UPDATE track_audio_features SET embedding = ? WHERE match_key = ?",
                               arguments: [p.blob, p.key])
                updated += db.changesCount
            }
            return updated
        }
    }

    /// Backfill `tracks.year` from the analyzer's file-tag years, keyed by
    /// match_key. Roon's Browse API doesn't expose the release year (album
    /// subtitles carry only the artist), so the analyzer — which reads the file
    /// tags — is the source. Only fills rows that lack a year so a Roon-provided
    /// value (should one ever appear) isn't clobbered. Returns rows updated.
    @discardableResult
    public func applyTrackYears(_ pairs: [(matchKey: String, year: Int)]) async throws -> Int {
        guard !pairs.isEmpty else { return 0 }
        let outPairs = pairs
        return try await pool.write { db -> Int in
            var updated = 0
            for p in outPairs {
                try db.execute(sql: """
                    UPDATE tracks SET year = ?
                    WHERE match_key = ? AND (year IS NULL OR year = 0)
                    """, arguments: [p.year, p.matchKey])
                updated += db.changesCount
            }
            return updated
        }
    }

    /// Persist the PCA-2D Music Map coordinates (Track E5d) by match_key.
    public func updateMapCoords(_ coords: [(matchKey: String, x: Double, y: Double)]) async throws {
        guard !coords.isEmpty else { return }
        try await pool.write { db in
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
    public func reconcileFeatureMatches(_ feats: [FeatureIdentity], apply: Bool) async throws -> AudioFeatureDiagnostic {
        // Bucket features by normalised primary artist, precomputing title tokens
        // so the inner loop is set intersections, not re-tokenisation.
        struct Cand { let matchKey: String; let tokens: Set<String> }
        var buckets: [String: [Cand]] = [:]
        for f in feats {
            let artistKey = TrackIdentity.normalise(TrackIdentity.primaryArtist(f.artist))
            buckets[artistKey, default: []].append(Cand(matchKey: f.matchKey, tokens: FuzzyMatch.tokens(f.title)))
        }
        // Immutable copy: the async pool.write closure is @Sendable.
        let outBuckets = buckets

        return try await pool.write { db in
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
                for cand in outBuckets[artistKey] ?? [] {
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
        public var loudness: Double?    // K-weighted LUFS; nil → loudness ignored in sequencing
        public var tags: String?
        public var imageKey: String?
    }

    /// Tracks with audio features inside the BPM window (incl. half/double-time),
    /// optional tag filter, deduped by title+artist.
    public func djCandidates(minBPM: Double, maxBPM: Double, tags: [String], excludeLive: Bool) async throws -> [DJCandidate] {
        try await pool.read { db in
            var sql = """
                SELECT t.id, t.title, t.artist, t.album, t.image_key, f.bpm, f.bpm_confidence, f.deezer_bpm, f.camelot, f.energy, f.loudness, f.tags
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
                // Octave-correct a low-confidence native BPM against the Deezer
                // dump reference (half/double-time fix). Pool membership is
                // unchanged — only the bpm VALUE moves, and only when our own
                // confidence is low and the reference agrees (TempoReconciler).
                let bpm = TempoReconciler.reconcile(
                    nativeBPM: r["bpm"] ?? 0, confidence: r["bpm_confidence"] ?? 1.0,
                    reference: r["deezer_bpm"])
                result.append(DJCandidate(
                    id: r["id"] ?? "", title: title, artist: artist, album: r["album"],
                    bpm: bpm, camelot: r["camelot"] ?? "", energy: r["energy"] ?? 0.5,
                    loudness: r["loudness"], tags: r["tags"],
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
        public var bpmConfidence: Double?    // 0…1 from the analyzer's tempo detector
        public var camelot: String
        /// RAW waveform RMS. Almost never what you want — it crushes into
        /// [0, 0.6] and orders acoustic folk above techno. Read `energySignal`
        /// instead; this stays exposed only as its fallback.
        public var rmsEnergy: Double?
        public var tags: [String]
        public var embedding: [Float]?       // 512-dim CLAP vector (Track E5)
        public var moods: [String: Float]    // mood → cosine, for Map colouring
        public var attributes: [String: Float]  // valence/danceability/… (zero-shot)
        public var mapX: Double?             // PCA-2D projection (Music Map)
        public var mapY: Double?
        public var popularity: Int?          // Deezer global rank (~0…1_000_000)
        public var genres: [String]          // REAL genres (MusicBrainz ∪ Deezer), lowercased —
                                             // unlike `tags`, these are not LLM-guessed
        public var year: Int?                // release year from the tracks row (sanity-clamped)
        public var loudness: Double?         // integrated LUFS (BS.1770), nil when unmeasured
        /// True when `tags` came from the CLAP zero-shot tagger (`clap-zs-*`)
        /// rather than the superseded Ollama metadata-guesser. Consumers that
        /// SCORE on tags must gate on this — the legacy tags were guessed from
        /// metadata the tagger never listened to.
        public var tagsAreCLAP: Bool

        /// The per-track energy signal: PERCEPTUAL arousal (CLAP) when present,
        /// else raw RMS. Arousal is semantic intensity derived from the
        /// embedding and orders busy-but-quiet vs loud-but-sparse correctly.
        /// 99.7% of the analyzed library has it; the fallback is for the tail.
        public var energySignal: Double? {
            if let a = attributes["arousal"] { return Double(a) }
            return rmsEnergy
        }

        /// Tags safe to SCORE on — empty for legacy Ollama-tagged rows.
        public var scorableTags: [String] { tagsAreCLAP ? tags : [] }

        public init(id: String, title: String, artist: String?, album: String?, imageKey: String?,
                    matchKey: String, bpm: Double?, camelot: String, rmsEnergy: Double?, tags: [String],
                    embedding: [Float]? = nil, moods: [String: Float] = [:],
                    mapX: Double? = nil, mapY: Double? = nil, bpmConfidence: Double? = nil,
                    attributes: [String: Float] = [:], popularity: Int? = nil,
                    genres: [String] = [], year: Int? = nil, loudness: Double? = nil,
                    tagsAreCLAP: Bool = true) {
            self.id = id; self.title = title; self.artist = artist; self.album = album
            self.imageKey = imageKey; self.matchKey = matchKey; self.bpm = bpm; self.camelot = camelot
            self.rmsEnergy = rmsEnergy; self.tags = tags; self.embedding = embedding; self.moods = moods
            self.mapX = mapX; self.mapY = mapY; self.bpmConfidence = bpmConfidence
            self.attributes = attributes; self.popularity = popularity
            self.genres = genres; self.year = year; self.loudness = loudness
            self.tagsAreCLAP = tagsAreCLAP
        }
    }

    /// Every library track that has analyzed audio features, deduped by
    /// title+artist. Source data for Sonic Radio / Fingerprint / Music Map.
    public func sonicTracks(excludeLive: Bool = true) async throws -> [SonicTrack] {
        try await pool.read { db in
            var sql = """
                SELECT t.id, t.title, t.artist, t.album, t.image_key, t.match_key, t.year,
                       f.bpm, f.bpm_confidence, f.camelot, f.energy, f.tags, f.tags_model, f.loudness,
                       f.embedding, f.moods, f.attributes, f.map_x, f.map_y, f.popularity,
                       (SELECT GROUP_CONCAT(genre, CHAR(31)) FROM track_mb_genres g
                         WHERE g.match_key = f.match_key) AS mb_genres,
                       (SELECT GROUP_CONCAT(genre, CHAR(31)) FROM track_deezer_genres g
                         WHERE g.match_key = f.match_key) AS deezer_genres
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
                var attributes: [String: Float] = [:]
                if let a = r["attributes"] as String?, let d = a.data(using: .utf8) {
                    attributes = (try? JSONDecoder().decode([String: Float].self, from: d)) ?? [:]
                }
                // Real genres: MusicBrainz ∪ Deezer, lowercased + deduped (order kept).
                var genres: [String] = []
                var seenGenre = Set<String>()
                for col in ["mb_genres", "deezer_genres"] {
                    guard let joined = r[col] as String? else { continue }
                    for g in joined.split(separator: "\u{1f}") {
                        let key = g.lowercased()
                        if !key.isEmpty, seenGenre.insert(key).inserted { genres.append(key) }
                    }
                }
                // Sanity-clamp the file-tag year: broken tags produce values like
                // 4018, which once minted a ghost "decade:4010" radio.
                let year = (r["year"] as Int?).flatMap { (1900...2035).contains($0) ? $0 : nil }
                out.append(SonicTrack(
                    id: r["id"] ?? "", title: title, artist: artist, album: r["album"],
                    imageKey: r["image_key"], matchKey: r["match_key"] ?? "",
                    bpm: r["bpm"], camelot: r["camelot"] ?? "", rmsEnergy: r["energy"], tags: tags,
                    embedding: embedding, moods: moods, mapX: r["map_x"], mapY: r["map_y"],
                    bpmConfidence: r["bpm_confidence"], attributes: attributes, popularity: r["popularity"],
                    genres: genres, year: year, loudness: r["loudness"],
                    // NULL provenance = the superseded Ollama guesser.
                    tagsAreCLAP: (r["tags_model"] as String?)?.isEmpty == false
                ))
            }
            return out
        }
    }

    /// Release year keyed by match_key, for decade-bucketed radios. Roon's Browse
    /// API doesn't expose the year (it's backfilled from analyzer file tags via
    /// `applyTrackYears`), so this only returns rows that actually have one.
    /// Sanity-bounded: a broken 4018 tag once minted a ghost "decade:4010" radio.
    public func yearByMatchKey() async throws -> [String: Int] {
        try await pool.read { db in
            var map: [String: Int] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT match_key, year FROM tracks WHERE year BETWEEN 1900 AND 2035"
            ) {
                guard let k = row["match_key"] as String?, let y = row["year"] as Int? else { continue }
                // Keep the earliest year seen for a match_key (original release).
                if let existing = map[k] { map[k] = min(existing, y) } else { map[k] = y }
            }
            return map
        }
    }

    /// Match keys that have analysed audio features — the set of tracks playable
    /// **on this device** (each was analysed from an on-disk file the analyser
    /// server can stream via `/audio`). Streaming-only library entries (Qobuz)
    /// were never analysed from a file, so they're absent here.
    public func playableMatchKeys() async throws -> Set<String> {
        try await pool.read { db in
            let keys = try String.fetchAll(
                db, sql: "SELECT DISTINCT match_key FROM track_audio_features WHERE match_key IS NOT NULL AND match_key != ''")
            return Set(keys)
        }
    }

    /// (matchKey, playCount, lastPlayedISO) for tracks the user has actually
    /// played, joining `listening_history` to `tracks` on LOWER(title)+LOWER(artist)
    /// — the v18 expression index keeps this fast. Powers the recency-weighted
    /// personal taste vector that biases every station toward the user's taste.
    /// `since` (ISO8601) restricts to plays at/after that moment — the Sonic DNA
    /// evolution view compares a recent window against all-time.
    public func playStatsByMatchKey(since: String? = nil) async throws -> [(matchKey: String, count: Int, lastPlayed: String)] {
        try await pool.read { db in
            // COUNT(DISTINCT h.id): the same song often has several `tracks` rows
            // (soundtrack + compilation + duplicate albums) sharing one match_key, so
            // the title+artist join fans one play out across them — COUNT(*) would
            // multiply the true play count by the number of duplicate rows.
            // played_at is stored ISO8601 (UTC), so a plain string >= compare works.
            let window = since != nil ? "AND h.played_at >= ?" : ""
            let args: StatementArguments = since != nil ? [since!] : []
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.match_key AS mk, COUNT(DISTINCT h.id) AS c, MAX(h.played_at) AS last
                FROM listening_history h
                JOIN tracks t ON LOWER(t.title) = LOWER(h.title) AND LOWER(t.artist) = LOWER(h.artist)
                WHERE t.match_key IS NOT NULL AND t.match_key <> '' \(window)
                GROUP BY t.match_key
            """, arguments: args)
            return rows.compactMap { r in
                guard let mk = r["mk"] as String?, let c = r["c"] as Int? else { return nil }
                return (mk, c, (r["last"] as String?) ?? "")
            }
        }
    }

    /// Cheap signature of the audio-feature / embedding state — folded into the
    /// library revision so remotes auto-re-pull when features or embeddings
    /// change (not only when the Roon library itself changes).
    public func audioFeaturesSignature() -> String {
        (try? pool.read { db -> String in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_audio_features") ?? 0
            let emb = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_audio_features WHERE embedding IS NOT NULL") ?? 0
            let last = try String.fetchOne(db, sql: "SELECT MAX(synced_at) FROM track_audio_features") ?? ""
            return "\(total)/\(emb)/\(last)"
        }) ?? ""
    }

    /// (features stored, tracks in the library that have a matching feature).
    public func audioFeaturesStats() async throws -> (total: Int, matched: Int) {
        try await pool.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_audio_features") ?? 0
            let matched = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tracks t JOIN track_audio_features f ON t.match_key = f.match_key
            """) ?? 0
            return (total, matched)
        }
    }

    /// Per-track duration (seconds) for the given content keys — batched IN
    /// queries, mirroring `loudnessByMatchKey`. Powers the generator's duration
    /// target (assemble to ~N minutes instead of N tracks). Keys without an
    /// analysed duration are simply absent.
    public func durationByMatchKey(_ keys: [String]) async -> [String: Double] {
        guard !keys.isEmpty else { return [:] }
        return (try? await pool.read { db -> [String: Double] in
            var out: [String: Double] = [:]
            var start = 0
            while start < keys.count {
                let slice = Array(keys[start..<min(start + 500, keys.count)])
                let placeholders = slice.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT match_key, duration FROM track_audio_features
                    WHERE duration IS NOT NULL AND match_key IN (\(placeholders))
                    """, arguments: StatementArguments(slice))
                for r in rows { out[r["match_key"]] = r["duration"] }
                start += 500
            }
            return out
        }) ?? [:]
    }

    /// Total play-time of the analysed library, in seconds (sum of track durations).
    /// Only analysed tracks carry a duration, so this tracks the "% geanalyseerd" figure.
    public func libraryDurationSeconds() async throws -> Double {
        try await pool.read { db in
            try Double.fetchOne(db, sql:
                "SELECT COALESCE(SUM(duration), 0) FROM track_audio_features WHERE duration IS NOT NULL") ?? 0
        }
    }

    // MARK: - Sync state

    public func syncStateValue(forKey key: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [key])
        }
    }

    public func setSyncState(key: String, value: String) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }
}
