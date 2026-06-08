import AudioAnalysis
import Foundation
import GRDB

/// Persistent store for analyzed track features on the analysis host.
/// Keyed by content match key so the app can join by the same key.
struct TrackFeatureRow {
    var matchKey: String
    var artist: String?
    var title: String?
    var album: String?
    var year: Int?
    var filePath: String
    var fileMtime: Double
    var bpm: Double
    var bpmConfidence: Double
    var keyRoot: String
    var keyMode: String
    var camelot: String
    var energy: Double
    var duration: Double
    var tags: String?          // JSON array
    var analyzedAt: String
}

final class FeatureStore {
    private let dbQueue: DatabaseQueue

    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try migrate()
    }

    static func defaultPath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RoonSage", isDirectory: true)
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
        }
    }

    /// True if this exact file (path + mtime) was already analyzed.
    func isAnalyzed(path: String, mtime: Double) -> Bool {
        (try? dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM track_features WHERE file_path = ? AND file_mtime = ?",
                              arguments: [path, mtime]) ?? false
        }) ?? false
    }

    func upsert(_ r: TrackFeatureRow) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO track_features
                  (match_key, artist, title, album, year, file_path, file_mtime,
                   bpm, bpm_confidence, key_root, key_mode, camelot, energy, duration, tags, analyzed_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(match_key) DO UPDATE SET
                  artist=excluded.artist, title=excluded.title, album=excluded.album, year=excluded.year,
                  file_path=excluded.file_path, file_mtime=excluded.file_mtime,
                  bpm=excluded.bpm, bpm_confidence=excluded.bpm_confidence,
                  key_root=excluded.key_root, key_mode=excluded.key_mode, camelot=excluded.camelot,
                  energy=excluded.energy, duration=excluded.duration, analyzed_at=excluded.analyzed_at
            """, arguments: [
                r.matchKey, r.artist, r.title, r.album, r.year, r.filePath, r.fileMtime,
                r.bpm, r.bpmConfidence, r.keyRoot, r.keyMode, r.camelot, r.energy, r.duration, r.tags, r.analyzedAt,
            ])
        }
    }

    func count() -> Int {
        (try? dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_features") ?? 0 }) ?? 0
    }

    func taggedCount() -> Int {
        (try? dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_features WHERE tags IS NOT NULL") ?? 0 }) ?? 0
    }

    /// Rows still needing LLM tags (metadata + features available).
    func untagged(limit: Int) -> [TrackFeatureRow] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM track_features WHERE tags IS NULL AND bpm IS NOT NULL LIMIT ?
            """, arguments: [limit]).map(Self.row)
        }) ?? []
    }

    func setTags(matchKey: String, tags: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE track_features SET tags = ? WHERE match_key = ?", arguments: [tags, matchKey])
        }
    }

    /// All features as a JSON array (keyed by match_key) for the app to sync.
    func exportJSON() -> Data {
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT match_key, artist, title, album, bpm, camelot, key_root, key_mode, energy, duration, tags
                FROM track_features WHERE bpm IS NOT NULL
            """)
        }) ?? []
        var arr: [[String: Any]] = []
        arr.reserveCapacity(rows.count)
        for r in rows {
            var obj: [String: Any] = [
                "match_key": r["match_key"] as String? ?? "",
                "artist": r["artist"] as String? ?? "",
                "title": r["title"] as String? ?? "",
                "album": r["album"] as String? ?? "",
                "bpm": r["bpm"] as Double? ?? 0,
                "camelot": r["camelot"] as String? ?? "",
                "key_root": r["key_root"] as String? ?? "",
                "key_mode": r["key_mode"] as String? ?? "",
                "energy": r["energy"] as Double? ?? 0,
                "duration": r["duration"] as Double? ?? 0,
            ]
            if let tags = r["tags"] as String? { obj["tags"] = tags }
            arr.append(obj)
        }
        return (try? JSONSerialization.data(withJSONObject: arr)) ?? Data("[]".utf8)
    }

    private static func row(_ r: Row) -> TrackFeatureRow {
        TrackFeatureRow(
            matchKey: r["match_key"], artist: r["artist"], title: r["title"], album: r["album"], year: r["year"],
            filePath: r["file_path"] ?? "", fileMtime: r["file_mtime"] ?? 0,
            bpm: r["bpm"] ?? 0, bpmConfidence: r["bpm_confidence"] ?? 0,
            keyRoot: r["key_root"] ?? "", keyMode: r["key_mode"] ?? "", camelot: r["camelot"] ?? "",
            energy: r["energy"] ?? 0, duration: r["duration"] ?? 0, tags: r["tags"], analyzedAt: r["analyzed_at"] ?? ""
        )
    }
}
