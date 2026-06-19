import AudioAnalysis
import Foundation
import GRDB

extension Data {
    /// Append a fixed-width unsigned integer in little-endian byte order.
    mutating func appendLE<T: FixedWidthInteger & UnsignedInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

/// Persistent store for analyzed track features on the analysis host.
public struct TrackFeatureRow: Sendable {
    public var matchKey: String
    public var artist: String?
    public var title: String?
    public var album: String?
    public var year: Int?
    public var filePath: String
    public var fileMtime: Double
    public var bpm: Double
    public var bpmConfidence: Double
    public var keyRoot: String
    public var keyMode: String
    public var camelot: String
    public var energy: Double
    public var duration: Double
    public var tags: String?
    public var analyzedAt: String
    // Track E5 — sonic embedding. `embedding` nil when CLAP unavailable/failed;
    // `embeddingModel` records the version it was processed at (gates re-analysis).
    public var embedding: [Float]?
    public var embeddingModel: String?
    public var moods: String?        // JSON: {"happy":0.4,…}
    public var attributes: String?   // JSON: {"valence":0.6,"danceability":0.4,…}

    public init(matchKey: String, artist: String?, title: String?, album: String?, year: Int?,
                filePath: String, fileMtime: Double, bpm: Double, bpmConfidence: Double,
                keyRoot: String, keyMode: String, camelot: String, energy: Double, duration: Double,
                tags: String?, analyzedAt: String,
                embedding: [Float]? = nil, embeddingModel: String? = nil, moods: String? = nil,
                attributes: String? = nil) {
        self.matchKey = matchKey; self.artist = artist; self.title = title; self.album = album
        self.year = year; self.filePath = filePath; self.fileMtime = fileMtime; self.bpm = bpm
        self.bpmConfidence = bpmConfidence; self.keyRoot = keyRoot; self.keyMode = keyMode
        self.camelot = camelot; self.energy = energy; self.duration = duration; self.tags = tags
        self.analyzedAt = analyzedAt
        self.embedding = embedding; self.embeddingModel = embeddingModel; self.moods = moods
        self.attributes = attributes
    }
}

public final class FeatureStore {
    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try migrate()
    }

    public static func defaultPath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RoonSageAnalyzer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("analyzer.db").path
    }

    private func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS track_features (
                    match_key      TEXT PRIMARY KEY,
                    artist         TEXT, title TEXT, album TEXT, year INTEGER,
                    file_path      TEXT NOT NULL,
                    file_mtime     REAL NOT NULL,
                    bpm            REAL, bpm_confidence REAL,
                    key_root       TEXT, key_mode TEXT, camelot TEXT,
                    energy         REAL, duration REAL,
                    tags           TEXT,
                    analyzed_at    TEXT NOT NULL
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_tf_path ON track_features(file_path, file_mtime)")

            // Incremental, idempotent column adds (Track E5). No versioned
            // migration table exists here — guard each ADD by inspecting the
            // current columns so re-running migrate() is safe.
            let cols = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(track_features)")
                .compactMap { $0["name"] as String? })
            func addColumn(_ name: String, _ decl: String) throws {
                if !cols.contains(name) {
                    try db.execute(sql: "ALTER TABLE track_features ADD COLUMN \(name) \(decl)")
                }
            }
            try addColumn("embedding", "BLOB")
            try addColumn("embedding_model", "TEXT")
            try addColumn("moods", "TEXT")
            try addColumn("map_x", "REAL")
            try addColumn("map_y", "REAL")
            try addColumn("attributes", "TEXT")
        }
    }

    // MARK: - [Float] <-> BLOB

    static func blob(_ v: [Float]) -> Data { v.withUnsafeBytes { Data($0) } }
    static func floats(_ d: Data) -> [Float] {
        d.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
    }

    public func isAnalyzed(path: String, mtime: Double) -> Bool {
        (try? dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM track_features WHERE file_path = ? AND file_mtime = ?",
                              arguments: [path, mtime]) ?? false
        }) ?? false
    }

    /// Whether a (path, mtime) row exists and the embedding model it carries.
    /// Lets the walker re-process for embeddings *without* recomputing scalars:
    /// `exists && model == currentVersion` ⇒ fully done; otherwise process.
    public func rowState(path: String, mtime: Double) -> (exists: Bool, model: String?) {
        let r = try? dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT embedding_model FROM track_features WHERE file_path = ? AND file_mtime = ?",
                             arguments: [path, mtime])
        }
        guard let row = r ?? nil else { return (false, nil) }
        return (true, row["embedding_model"] as String?)
    }

    /// Update only the embedding columns for an existing row — used when scalars
    /// are already present and just the embedding needs (re)computing.
    public func setEmbedding(path: String, mtime: Double,
                             embedding: [Float]?, model: String, moods: String?,
                             attributes: String? = nil) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE track_features SET embedding = ?, embedding_model = ?, moods = ?, attributes = ?
                WHERE file_path = ? AND file_mtime = ?
                """, arguments: [embedding.map(Self.blob), model, moods, attributes, path, mtime])
        }
    }

    /// Rows that have an embedding but no attributes yet — the no-re-scan backfill
    /// set. Returns (path, mtime, embedding) so attributes can be derived from the
    /// stored vector without touching the audio file.
    public func attributeBackfillRows(limit: Int) -> [(path: String, mtime: Double, embedding: [Float])] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT file_path, file_mtime, embedding FROM track_features
                WHERE embedding IS NOT NULL AND attributes IS NULL LIMIT ?
                """, arguments: [limit])
        })?.compactMap { r in
            guard let blob = r["embedding"] as Data? else { return nil }
            return (r["file_path"] ?? "", r["file_mtime"] ?? 0, Self.floats(blob))
        } ?? []
    }

    public func setAttributes(path: String, mtime: Double, attributes: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE track_features SET attributes = ? WHERE file_path = ? AND file_mtime = ?",
                           arguments: [attributes, path, mtime])
        }
    }

    /// Count of embedded rows still missing attributes (drives the backfill UI).
    public func missingAttributesCount() -> Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_features WHERE embedding IS NOT NULL AND attributes IS NULL") ?? 0
        }) ?? 0
    }

    public func upsert(_ r: TrackFeatureRow) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO track_features
                  (match_key, artist, title, album, year, file_path, file_mtime,
                   bpm, bpm_confidence, key_root, key_mode, camelot, energy, duration, tags, analyzed_at,
                   embedding, embedding_model, moods, attributes)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(match_key) DO UPDATE SET
                  artist=excluded.artist, title=excluded.title, album=excluded.album, year=excluded.year,
                  file_path=excluded.file_path, file_mtime=excluded.file_mtime,
                  bpm=excluded.bpm, bpm_confidence=excluded.bpm_confidence,
                  key_root=excluded.key_root, key_mode=excluded.key_mode, camelot=excluded.camelot,
                  energy=excluded.energy, duration=excluded.duration, analyzed_at=excluded.analyzed_at,
                  embedding=excluded.embedding, embedding_model=excluded.embedding_model, moods=excluded.moods,
                  attributes=excluded.attributes
            """, arguments: [
                r.matchKey, r.artist, r.title, r.album, r.year, r.filePath, r.fileMtime,
                r.bpm, r.bpmConfidence, r.keyRoot, r.keyMode, r.camelot, r.energy, r.duration, r.tags, r.analyzedAt,
                r.embedding.map(Self.blob), r.embeddingModel, r.moods, r.attributes,
            ])
        }
    }

    /// Full row for a (path, mtime), including the embedding BLOB. Used by tests
    /// and the `/embeddings` export.
    public func featureRow(path: String, mtime: Double) -> TrackFeatureRow? {
        try? dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM track_features WHERE file_path = ? AND file_mtime = ?",
                             arguments: [path, mtime]).map(Self.row)
        }
    }

    public func count() -> Int {
        (try? dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_features") ?? 0 }) ?? 0
    }

    /// Number of tracks that carry a CLAP embedding — used to build the
    /// analyzer's feature-revision signature.
    public func embeddedCount() -> Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_features WHERE embedding IS NOT NULL") ?? 0
        }) ?? 0
    }

    public func taggedCount() -> Int {
        (try? dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_features WHERE tags IS NOT NULL") ?? 0 }) ?? 0
    }

    public func untagged(limit: Int) -> [TrackFeatureRow] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM track_features WHERE tags IS NULL AND bpm IS NOT NULL LIMIT ?",
                             arguments: [limit]).map(Self.row)
        }) ?? []
    }

    public func setTags(matchKey: String, tags: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE track_features SET tags = ? WHERE match_key = ?", arguments: [tags, matchKey])
        }
    }

    /// `includeEmbedding` adds the 512-dim vector as base64 (Float32 LE) per
    /// track — large, so off by default; the binary `/embeddings` endpoint is
    /// the preferred bulk path. `moods` + `embedding_model` are always included
    /// (small) and backward-compatible (older clients ignore unknown keys).
    public func exportJSON(includeEmbedding: Bool = false) -> Data {
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT match_key, artist, title, album, year, bpm, bpm_confidence, camelot, key_root, key_mode, energy, duration,
                       tags, moods, attributes, embedding_model\(includeEmbedding ? ", embedding" : "")
                FROM track_features WHERE bpm IS NOT NULL
            """)
        }) ?? []
        var arr: [[String: Any]] = []
        arr.reserveCapacity(rows.count)
        for r in rows {
            // Compute the match key fresh from artist/title so it always reflects
            // the current TrackIdentity scheme — the stored PK may predate a
            // normaliser change (no re-analysis needed to re-key the export).
            let matchKey = TrackIdentity.matchKey(
                artist: r["artist"], album: r["album"], title: r["title"])
            var obj: [String: Any] = [
                "match_key": matchKey,
                "artist": r["artist"] as String? ?? "",
                "title": r["title"] as String? ?? "",
                "album": r["album"] as String? ?? "",
                "bpm": r["bpm"] as Double? ?? 0,
                "bpm_confidence": r["bpm_confidence"] as Double? ?? 0,
                "camelot": r["camelot"] as String? ?? "",
                "key_root": r["key_root"] as String? ?? "",
                "key_mode": r["key_mode"] as String? ?? "",
                "energy": r["energy"] as Double? ?? 0,
                "duration": r["duration"] as Double? ?? 0,
            ]
            if let year = r["year"] as Int?, year > 0 { obj["year"] = year }
            if let tags = r["tags"] as String? { obj["tags"] = tags }
            if let moods = r["moods"] as String? { obj["moods"] = moods }
            if let attributes = r["attributes"] as String? { obj["attributes"] = attributes }
            if let model = r["embedding_model"] as String? { obj["embedding_model"] = model }
            if includeEmbedding, let blob = r["embedding"] as Data? {
                obj["embedding"] = blob.base64EncodedString()
            }
            arr.append(obj)
        }
        return (try? JSONSerialization.data(withJSONObject: arr)) ?? Data("[]".utf8)
    }

    /// All (match_key, embedding) pairs that have an embedding. match_key is
    /// recomputed fresh from artist/title to match the current scheme.
    public func allEmbeddings() -> [(matchKey: String, embedding: [Float])] {
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT artist, album, title, embedding FROM track_features WHERE embedding IS NOT NULL
            """)
        }) ?? []
        return rows.compactMap { r in
            guard let blob = r["embedding"] as Data? else { return nil }
            let key = TrackIdentity.matchKey(artist: r["artist"], album: r["album"], title: r["title"])
            return (key, Self.floats(blob))
        }
    }

    /// Compact binary embedding bundle for the `/embeddings` endpoint:
    ///   "RSEB" | ver:UInt8=1 | dim:UInt32LE | count:UInt32LE
    ///   then count × ( keyLen:UInt16LE | key:UTF8 | dim×Float32LE )
    public func embeddingsBlob() -> Data {
        let all = allEmbeddings()
        let dim = UInt32(all.first?.embedding.count ?? CLAPModel.embeddingDim)
        var out = Data("RSEB".utf8)
        out.append(1)
        out.appendLE(dim)
        out.appendLE(UInt32(all.count))
        for (key, vec) in all where vec.count == Int(dim) {
            let kb = Array(key.utf8)
            out.appendLE(UInt16(kb.count))
            out.append(contentsOf: kb)
            vec.withUnsafeBytes { out.append(contentsOf: $0) }
        }
        return out
    }

    private static func row(_ r: Row) -> TrackFeatureRow {
        TrackFeatureRow(
            matchKey: r["match_key"], artist: r["artist"], title: r["title"], album: r["album"], year: r["year"],
            filePath: r["file_path"] ?? "", fileMtime: r["file_mtime"] ?? 0,
            bpm: r["bpm"] ?? 0, bpmConfidence: r["bpm_confidence"] ?? 0,
            keyRoot: r["key_root"] ?? "", keyMode: r["key_mode"] ?? "", camelot: r["camelot"] ?? "",
            energy: r["energy"] ?? 0, duration: r["duration"] ?? 0, tags: r["tags"], analyzedAt: r["analyzed_at"] ?? "",
            embedding: (r["embedding"] as Data?).map(FeatureStore.floats),
            embeddingModel: r["embedding_model"], moods: r["moods"], attributes: r["attributes"]
        )
    }
}
