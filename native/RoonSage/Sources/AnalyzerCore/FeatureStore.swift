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
    public var loudness: Double?      // K-weighted LUFS (BS.1770); nil when uncomputed
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
                tags: String?, analyzedAt: String, loudness: Double? = nil,
                embedding: [Float]? = nil, embeddingModel: String? = nil, moods: String? = nil,
                attributes: String? = nil) {
        self.matchKey = matchKey; self.artist = artist; self.title = title; self.album = album
        self.year = year; self.filePath = filePath; self.fileMtime = fileMtime; self.bpm = bpm
        self.bpmConfidence = bpmConfidence; self.keyRoot = keyRoot; self.keyMode = keyMode
        self.camelot = camelot; self.energy = energy; self.duration = duration; self.tags = tags
        self.analyzedAt = analyzedAt; self.loudness = loudness
        self.embedding = embedding; self.embeddingModel = embeddingModel; self.moods = moods
        self.attributes = attributes
    }
}

public final class FeatureStore {
    private let dbQueue: DatabaseQueue
    public let databasePath: String

    // (PERF-H1) Memoized current-scheme [matchKey → real file_path] map. The
    // `/audio` endpoint resolves a client's CURRENT-scheme key; when it doesn't
    // match the stored PK (older-scheme rows that were never re-analysed) the
    // resolution used to fall back to a FULL TABLE SCAN that recomputed
    // TrackIdentity.matchKey for every row — on EVERY audio Range request. This
    // caches that map, rebuilt only when the corpus signature changes (same gate
    // the /features HTTP cache uses), so the fallback becomes an O(1) lookup. The
    // in-memory map is process-scoped: a normaliser (scheme) change ships in a new
    // binary → restart → it rebuilds with the current scheme, so it never serves a
    // stale key without re-analysis. `playableMatchKeys()` reuses the same map.
    private let pathMapLock = NSLock()
    private var pathMap: [String: String]?
    private var pathMapSig = ""

    public init(path: String) throws {
        databasePath = path
        dbQueue = try DatabaseQueue(path: path)
        try migrate()
    }

    /// Reclaim free pages / defragment the file. Safe maintenance; can take a
    /// while on a big DB. The server-of-record's analyses live here.
    public func vacuum() throws {
        try dbQueue.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
    }

    /// Write a consistent snapshot copy to `path` (clean, defragmented). Uses
    /// `VACUUM INTO`, which is transactional — no need to stop the server.
    public func backup(toPath path: String) throws {
        let escaped = path.replacingOccurrences(of: "'", with: "''")
        try dbQueue.writeWithoutTransaction { db in try db.execute(sql: "VACUUM INTO '\(escaped)'") }
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
            // MusicBrainz genre enrichment (analyzer-side). `mb_genres` is a JSON
            // string array of controlled-vocabulary genres; `mb_checked_at` marks
            // a row as enriched (incl. "looked up, found nothing") so the worker
            // is resumable and never re-queries a finished album.
            try addColumn("mb_genres", "TEXT")
            try addColumn("mb_checked_at", "TEXT")
            // Artist-level genre fallback: when neither the album nor the recording
            // lookup found genres (MB's release/recording genre coverage is sparse —
            // ~58% of tracks came back empty), the artist almost always carries tags.
            // `mb_artist_checked_at` marks a row as having had that fallback attempted
            // (incl. "found nothing") so it's resumable and re-runs over the existing
            // checked-but-empty backlog without re-doing album lookups.
            try addColumn("mb_artist_checked_at", "TEXT")
            // Deezer global popularity (`rank`, ~0…1_000_000). `popularity_checked_at`
            // marks a row as looked up (incl. "found nothing" → popularity NULL) so
            // the worker is resumable and never re-queries a finished track.
            try addColumn("popularity", "INTEGER")
            try addColumn("popularity_checked_at", "TEXT")
            // F3: perceptual loudness (K-weighted LUFS, BS.1770) — a separate factor
            // in the DJ-set sequencer, alongside BPM/Camelot/energy. NULL until a
            // (re-)analysis computes it; the DJ builder falls back when absent.
            // `loudness_checked_at` marks a row the LoudnessBackfill has attempted
            // (incl. a failed decode → value stays NULL) so it's resumable and never
            // re-decodes a finished/unreadable file.
            try addColumn("loudness", "REAL")
            try addColumn("loudness_checked_at", "TEXT")
            // Dataset-sidecar identity (offline MusicMoveArr dumps). `isrc` and
            // `recording_mbid` are hard cross-source identity; `deezer_bpm` /
            // `deezer_gain` are the dump's DJ metrics (a cross-check next to the
            // native analyzer, not the source of truth). `dataset_checked_at`
            // marks a row as matched against the sidecar (incl. "no match") so
            // the importer is resumable and never redoes a finished row.
            try addColumn("isrc", "TEXT")
            try addColumn("recording_mbid", "TEXT")
            try addColumn("deezer_bpm", "REAL")
            try addColumn("deezer_gain", "REAL")
            try addColumn("dataset_checked_at", "TEXT")
            // Dataset quick-win metadata (same sidecar, same import pass): UPC hard-
            // identifies the ALBUM the way isrc does the track; `label` + `release_date`
            // are more precise than Roon's subtitle-parsed year; `explicit` is a flag
            // Roon never exposes. All NULL until a matching sidecar row supplies them.
            try addColumn("album_upc", "TEXT")
            try addColumn("label", "TEXT")
            try addColumn("release_date", "TEXT")
            try addColumn("explicit", "INTEGER")
            // Deezer genre backfill (DeezerGenreEnricher) — a second genre signal
            // alongside MusicBrainz (mb_genres), whose per-release coverage is
            // sparse. `deezer_genre_checked_at` marks a row as looked up (incl.
            // "no match") so the worker is resumable.
            try addColumn("deezer_genres", "TEXT")
            try addColumn("deezer_genre_checked_at", "TEXT")
            // Zero-shot CLAP tagging (ClapTagger): which vocabulary version wrote
            // this row's `tags`. NULL = legacy Ollama tags (or untagged); the
            // tagger re-stamps every row whose version lags, so bumping
            // `ClapTagVocabulary.version` retags the library resumable-y.
            try addColumn("tags_model", "TEXT")

            // Genre hierarchy (parent ← subgenre), built from MusicBrainz. `parent`
            // is NULL for a root genre (or when MB exposes no relation for it).
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS genre_taxonomy (
                    genre  TEXT PRIMARY KEY,
                    parent TEXT,
                    mbid   TEXT
                )
            """)

            // Small key/value table for analyzer-internal flags — e.g. whether the
            // full MusicBrainz genre vocabulary has been fetched completely (so a
            // partial fetch is retried instead of cementing a broken hierarchy).
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS analyzer_meta (
                    key   TEXT PRIMARY KEY,
                    value TEXT
                )
            """)

            // Preview-embedding backfill memo: which library-only tracks (no local
            // file — Qobuz-added) we already tried to resolve to a Deezer 30s
            // preview, INCLUDING "looked, found nothing" — so the trickle worker
            // is resumable and never re-queries a finished track. Successful rows
            // land in track_features under a "preview://deezer/…" pseudo path.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS preview_lookups (
                    match_key  TEXT PRIMARY KEY,
                    found      INTEGER NOT NULL DEFAULT 0,
                    checked_at TEXT NOT NULL
                )
            """)
        }
    }

    // MARK: - Preview-embedding backfill (Qobuz-only tracks)

    /// Marker prefix of feature rows analyzed from a streaming PREVIEW instead of
    /// a local file. Excluded from local-playback (`/audio`, playable keys);
    /// everything else — export, embeddings bundle, radios — treats them as
    /// regular analyzed tracks.
    public static let previewPathPrefix = "preview://deezer/"

    public func hasRow(matchKey: String) -> Bool {
        (try? dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM track_features WHERE match_key = ?",
                              arguments: [matchKey]) ?? false
        }) ?? false
    }

    public func previewChecked(matchKey: String) -> Bool {
        (try? dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM preview_lookups WHERE match_key = ?",
                              arguments: [matchKey]) ?? false
        }) ?? false
    }

    public func markPreviewChecked(matchKey: String, found: Bool, checkedAt: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO preview_lookups (match_key, found, checked_at) VALUES (?, ?, ?)
                ON CONFLICT(match_key) DO UPDATE SET found=excluded.found, checked_at=excluded.checked_at
            """, arguments: [matchKey, found ? 1 : 0, checkedAt])
        }
    }

    /// Analyzed-from-preview rows currently in the store.
    public func previewRowCount() -> Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_features WHERE file_path LIKE ?",
                             arguments: [Self.previewPathPrefix + "%"]) ?? 0
        }) ?? 0
    }

    /// Preview lookups attempted (found or not) — the worker's resumability meter.
    public func previewCheckedCount() -> Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM preview_lookups") ?? 0
        }) ?? 0
    }

    // MARK: - [Float] <-> BLOB

    static func blob(_ v: [Float]) -> Data { v.withUnsafeBytes { Data($0) } }
    static func floats(_ d: Data) -> [Float] {
        d.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
    }

    /// Sub-second file mtimes don't round-trip bit-stable through Swift's
    /// `Date.timeIntervalSince1970`, so a fresh disk read drifts a few ULPs from
    /// the stored value. EXACT float equality on `file_mtime` then misses and the
    /// walker re-analyses the file every pass (v3 stagnation, 2026-07-17). Match
    /// within a tolerance far below any real file edit (which moves mtime by
    /// seconds); the sentinel -1 (markAllForReanalysis) stays far outside it.
    /// Interpolated into SQL as a compile-time constant — no user input.
    private static let mtimeMatchSQL = "abs(file_mtime - ?) < 0.5"

    public func isAnalyzed(path: String, mtime: Double) -> Bool {
        (try? dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM track_features WHERE file_path = ? AND \(Self.mtimeMatchSQL)",
                              arguments: [path, mtime]) ?? false
        }) ?? false
    }

    /// Whether a (path, mtime) row exists and the embedding model it carries.
    /// Lets the walker re-process for embeddings *without* recomputing scalars:
    /// `exists && model == currentVersion` ⇒ fully done; otherwise process.
    public func rowState(path: String, mtime: Double) -> (exists: Bool, model: String?) {
        let r = try? dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT embedding_model FROM track_features WHERE file_path = ? AND \(Self.mtimeMatchSQL)",
                             arguments: [path, mtime])
        }
        guard let row = r ?? nil else { return (false, nil) }
        return (true, row["embedding_model"] as String?)
    }

    /// Row identity as the walker sees it, looked up by the STORAGE key
    /// (`match_key`, the primary key) instead of by (file_path, file_mtime).
    ///
    /// The skip-check MUST use the same key the upsert conflicts on. `matchKey`
    /// is `primaryArtist␟cleanTitle` — album- and duration-agnostic by design —
    /// so two different files can normalise to one key (24bit/16bit versions,
    /// live vs studio, a track on both album and compilation: 13.100 files over
    /// 5.743 keys in this library). Keyed on the path, each of those files misses
    /// the other's row, re-analyses, and overwrites it in turn: the walk
    /// ping-pongs and makes zero net progress (2026-07-17 stagnation).
    ///
    /// Returns nil when no row carries this key.
    public func rowState(matchKey: String) -> (model: String?, filePath: String?, fileMtime: Double)? {
        let r = try? dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT embedding_model, file_path, file_mtime FROM track_features WHERE match_key = ?
                """, arguments: [matchKey])
        }
        guard let row = r ?? nil else { return nil }
        return (row["embedding_model"] as String?, row["file_path"] as String?, row["file_mtime"] as Double? ?? 0)
    }

    /// Embedding-only update keyed on `match_key` — the counterpart of
    /// `rowState(matchKey:)` for the walker's `.embeddingOnly` mode, so the write
    /// lands on the row the skip-check actually consulted.
    public func setEmbedding(matchKey: String,
                             embedding: [Float]?, model: String, moods: String?,
                             attributes: String? = nil) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE track_features SET embedding = ?, embedding_model = ?, moods = ?, attributes = ?
                WHERE match_key = ?
                """, arguments: [embedding.map(Self.blob), model, moods, attributes, matchKey])
        }
    }

    /// Update only the embedding columns for an existing row — used when scalars
    /// are already present and just the embedding needs (re)computing.
    public func setEmbedding(path: String, mtime: Double,
                             embedding: [Float]?, model: String, moods: String?,
                             attributes: String? = nil) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE track_features SET embedding = ?, embedding_model = ?, moods = ?, attributes = ?
                WHERE file_path = ? AND \(Self.mtimeMatchSQL)
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

    /// Embedded rows whose attributes JSON is missing `key` — the re-derivation
    /// feed when a NEW axis (e.g. `arousal`) is added: the plain backfill only
    /// sees `attributes IS NULL`, so existing 4-axis rows would never gain it.
    /// Derived from the STORED embedding, so no audio is re-read.
    ///
    /// Paginated by `rowid` (NOT by the shrinking NOT-LIKE set): advancing a
    /// monotonic cursor makes the whole migration O(n), where re-running the
    /// LIKE scan from the start each batch was O(n²) — the cause of the ~5 rows/s
    /// crawl. Returns the max rowid seen so the caller advances past it.
    public func attributeRefreshRows(missingKey key: String, afterRowid: Int64, limit: Int)
        -> [(rowid: Int64, path: String, mtime: Double, embedding: [Float])] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT rowid, file_path, file_mtime, embedding FROM track_features
                WHERE rowid > ?
                  AND embedding IS NOT NULL
                  AND attributes IS NOT NULL
                  AND attributes NOT LIKE ?
                ORDER BY rowid LIMIT ?
                """, arguments: [afterRowid, "%\"\(key)\"%", limit])
        })?.compactMap { r in
            guard let blob = r["embedding"] as Data? else { return nil }
            return (r["rowid"] ?? 0, r["file_path"] ?? "", r["file_mtime"] ?? 0, Self.floats(blob))
        } ?? []
    }

    /// The largest rowid in the table — the pagination end sentinel.
    public func maxRowid() -> Int64 {
        (try? dbQueue.read { db in try Int64.fetchOne(db, sql: "SELECT MAX(rowid) FROM track_features") ?? 0 }) ?? 0
    }

    /// Write many (path, mtime → attributes) in ONE transaction — the re-derive
    /// path updates tens of thousands of rows, and a write-per-row is tens of
    /// thousands of WAL commits contending with the live server.
    public func setAttributesBatch(_ rows: [(path: String, mtime: Double, attributes: String)]) throws {
        guard !rows.isEmpty else { return }
        try dbQueue.write { db in
            for r in rows {
                try db.execute(sql: "UPDATE track_features SET attributes = ? WHERE file_path = ? AND file_mtime = ?",
                               arguments: [r.attributes, r.path, r.mtime])
            }
        }
    }

    /// Count of embedded rows whose attributes lack `key` (drives the re-derive UI).
    public func attributesMissingKeyCount(_ key: String) -> Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM track_features
                WHERE embedding IS NOT NULL AND attributes IS NOT NULL AND attributes NOT LIKE ?
                """, arguments: ["%\"\(key)\"%"]) ?? 0
        }) ?? 0
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
        try upsertBatch([r])
    }

    /// Upsert many rows in ONE write transaction. A per-row `upsert()` opens a
    /// transaction (and WAL commit / fsync) each call — at 24-50k tracks that's as
    /// many commits. The walker buffers results and flushes through here.
    public func upsertBatch(_ rows: [TrackFeatureRow]) throws {
        guard !rows.isEmpty else { return }
        try dbQueue.write { db in
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO track_features
                      (match_key, artist, title, album, year, file_path, file_mtime,
                       bpm, bpm_confidence, key_root, key_mode, camelot, energy, duration, tags, analyzed_at,
                       embedding, embedding_model, moods, attributes, loudness)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(match_key) DO UPDATE SET
                      artist=excluded.artist, title=excluded.title, album=excluded.album, year=excluded.year,
                      file_path=excluded.file_path, file_mtime=excluded.file_mtime,
                      bpm=excluded.bpm, bpm_confidence=excluded.bpm_confidence,
                      key_root=excluded.key_root, key_mode=excluded.key_mode, camelot=excluded.camelot,
                      energy=excluded.energy, duration=excluded.duration, analyzed_at=excluded.analyzed_at,
                      embedding=excluded.embedding, embedding_model=excluded.embedding_model, moods=excluded.moods,
                      attributes=excluded.attributes, loudness=excluded.loudness
                """, arguments: [
                    r.matchKey, r.artist, r.title, r.album, r.year, r.filePath, r.fileMtime,
                    r.bpm, r.bpmConfidence, r.keyRoot, r.keyMode, r.camelot, r.energy, r.duration, r.tags, r.analyzedAt,
                    r.embedding.map(Self.blob), r.embeddingModel, r.moods, r.attributes, r.loudness,
                ])
            }
        }
    }

    /// Mark EVERY row for full re-analysis on the next library walk. The walker
    /// looks the row up by `match_key` and treats a NEGATIVE stored `file_mtime`
    /// as an explicit re-analysis request → mode .full (scalars + embedding both
    /// recomputed — from the full track since the AudioMuse-parity defaults).
    /// The first full pass writes the file's real mtime back, so the sentinel
    /// clears itself and progress is monotone (it is not a "looks new" trick:
    /// keying the skip-check on the path made colliding files overwrite each
    /// other forever — see `rowState(matchKey:)`).
    /// Enrichment survives: the upsert's ON CONFLICT clause never touches
    /// tags/mb_genres/popularity. Returns the number of rows marked.
    @discardableResult
    public func markAllForReanalysis() throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE track_features SET file_mtime = -1")
            return db.changesCount
        }
    }

    /// Cheap signature of the feature corpus for HTTP response caching + the
    /// server feature-sync's change gate: any add (count), embed, tag, enrichment
    /// or attribute-backfill changes one of the COUNTs, so a stale cache is never
    /// served and clients re-pull.
    public func contentSignature() -> String {
        (try? dbQueue.read { db in
            let r = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COUNT(embedding) AS e, COUNT(tags) AS t, COUNT(attributes) AS a,
                       COUNT(mb_genres) AS g, COUNT(popularity) AS p,
                       SUM(CASE WHEN attributes LIKE '%"arousal"%' THEN 1 ELSE 0 END) AS ar,
                       SUM(CASE WHEN tags_model = ? THEN 1 ELSE 0 END) AS tm
                FROM track_features
            """, arguments: [ClapTagVocabulary.version])
            // `g`/`p` fold in MB + popularity progress. `ar` (arousal coverage)
            // is folded in because adding a NEW attribute AXIS to already-populated
            // `attributes` JSON leaves COUNT(attributes) unchanged — without this
            // term a re-derived axis would never propagate to clients / library.db.
            // `tm` is the same trap for the CLAP retag: it REPLACES tags in place,
            // so COUNT(tags) never moves — without this term retagged rows would
            // never reach clients.
            return "\(r?["c"] as Int? ?? 0)/\(r?["e"] as Int? ?? 0)/\(r?["t"] as Int? ?? 0)/\(r?["a"] as Int? ?? 0)/\(r?["g"] as Int? ?? 0)/\(r?["p"] as Int? ?? 0)/\(r?["ar"] as Int? ?? 0)/\(r?["tm"] as Int? ?? 0)"
        }) ?? "0/0/0/0/0/0/0/0"
    }

    /// Resolve a streamable on-disk file for a track's match key — backs the
    /// `/audio` endpoint (local playback on the phone). Tries the stored PK
    /// first, then falls back to a scan that recomputes the key under the
    /// CURRENT TrackIdentity scheme: the `/features` export re-keys this way, so
    /// a client's key can differ from an older stored PK after a normaliser
    /// change (no re-analysis needed to re-key). Returns nil when nothing maps —
    /// i.e. the track is not locally playable (e.g. a Qobuz-only library entry
    /// that was never analysed from a file).
    public func filePath(forMatchKey key: String) -> String? {
        // Preview-analyzed rows have a pseudo path — never serveable audio.
        func real(_ p: String?) -> String? {
            guard let p, !p.isEmpty, !p.hasPrefix(Self.previewPathPrefix) else { return nil }
            return p
        }
        if let p = real((try? dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT file_path FROM track_features WHERE match_key = ?",
                                arguments: [key])
        }) ?? nil) { return p }
        // Fallback: the stored PK is an older-scheme key. Resolve against the
        // memoized current-scheme map instead of rescanning the whole table.
        return currentKeyPathMap()[key]
    }

    /// Current-scheme `[matchKey → real file_path]` for every locally-playable
    /// row, memoized and rebuilt only when the corpus signature changes (see the
    /// pathMap field note). Only real, non-preview paths are included, so a hit is
    /// always a serveable file. First path wins on a key collision.
    private func currentKeyPathMap() -> [String: String] {
        let sig = contentSignature()
        pathMapLock.lock()
        if pathMapSig == sig, let cached = pathMap { pathMapLock.unlock(); return cached }
        pathMapLock.unlock()

        let built: [String: String] = (try? dbQueue.read { db -> [String: String] in
            let rows = try Row.fetchAll(db, sql: "SELECT artist, album, title, file_path FROM track_features")
            var m = [String: String](minimumCapacity: rows.count)
            for r in rows {
                guard let p = r["file_path"] as String?, !p.isEmpty, !p.hasPrefix(Self.previewPathPrefix) else { continue }
                let k = TrackIdentity.matchKey(artist: r["artist"], album: r["album"], title: r["title"])
                if m[k] == nil { m[k] = p }
            }
            return m
        }) ?? [:]

        pathMapLock.lock(); pathMap = built; pathMapSig = sig; pathMapLock.unlock()
        return built
    }

    /// The locally-playable set: every match key (current scheme) that has an
    /// on-disk file. Every analysed track has a `file_path` (NOT NULL), so this
    /// is effectively "tracks the analyser walked from disk". Recomputes keys to
    /// match the `/features` export the client syncs against.
    public func playableMatchKeys() -> Set<String> {
        // The memoized map's keys ARE the current-scheme keys of every real,
        // non-preview (i.e. locally-playable) row — the same filter this used to
        // scan for, now shared with `/audio` resolution instead of re-scanned.
        Set(currentKeyPathMap().keys)
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

    // MARK: - Zero-shot CLAP tagging (ClapTagger)

    /// Rows still lacking tags from `version`: legacy Ollama tags, an older
    /// vocabulary, or no tags at all. Only embedded rows qualify — the tagger
    /// scores audio, not metadata.
    public func rowsNeedingClapTags(version: String, limit: Int) -> [(matchKey: String, embedding: [Float])] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT match_key, embedding FROM track_features
                WHERE embedding IS NOT NULL AND (tags_model IS NULL OR tags_model <> ?)
                LIMIT ?
                """, arguments: [version, limit]).compactMap { r in
                guard let mk = r["match_key"] as String?, let d = r["embedding"] as Data? else { return nil }
                return (mk, Self.floats(d))
            }
        }) ?? []
    }

    /// An evenly-spread sample of embeddings for per-term calibration —
    /// deterministic (rowid stride), no ORDER BY RANDOM() churn.
    public func embeddingSample(limit: Int) -> [[Float]] {
        (try? dbQueue.read { db in
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_features WHERE embedding IS NOT NULL") ?? 0
            guard n > 0 else { return [] }
            let step = max(1, n / max(1, limit))
            return try Row.fetchAll(db, sql: """
                SELECT embedding FROM track_features
                WHERE embedding IS NOT NULL AND (rowid % ?) = 0
                LIMIT ?
                """, arguments: [step, limit]).compactMap { r in
                (r["embedding"] as Data?).map(Self.floats)
            }
        }) ?? []
    }

    /// Batch-write one tagging pass: tags + version stamp in a single write.
    public func setClapTags(_ updates: [(matchKey: String, tags: String)], model: String) throws {
        try dbQueue.write { db in
            for u in updates {
                try db.execute(sql: "UPDATE track_features SET tags = ?, tags_model = ? WHERE match_key = ?",
                               arguments: [u.tags, model, u.matchKey])
            }
        }
    }

    /// Rows already stamped with `version` — the tagger's resumability meter.
    public func clapTaggedCount(version: String) -> Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_features WHERE tags_model = ?",
                             arguments: [version]) ?? 0
        }) ?? 0
    }

    // MARK: - MusicBrainz genre enrichment

    /// One album's analyzed tracks: a single MB release lookup enriches them all.
    public struct MBAlbumGroup: Sendable {
        public let artist: String
        public let album: String
        public let matchKeys: [String]
    }

    /// Up to `limit` albums that still have an un-enriched analyzed track. One MB
    /// lookup per album (album-level matching); `matchKeys` is every track on the
    /// album so they're all marked done in one write. Resumable: an interrupted
    /// run just re-selects the albums it didn't reach.
    public func albumsNeedingMBGenres(limit: Int) -> [MBAlbumGroup] {
        (try? dbQueue.read { db in
            let albums = try Row.fetchAll(db, sql: """
                SELECT artist, album FROM track_features
                WHERE mb_checked_at IS NULL AND bpm IS NOT NULL
                  AND album IS NOT NULL AND album != '' AND artist IS NOT NULL AND artist != ''
                GROUP BY LOWER(artist), LOWER(album)
                ORDER BY artist, album
                LIMIT ?
            """, arguments: [limit])
            var out: [MBAlbumGroup] = []
            for a in albums {
                guard let artist = a["artist"] as String?, let album = a["album"] as String? else { continue }
                let mks = try String.fetchAll(db, sql: """
                    SELECT match_key FROM track_features
                    WHERE LOWER(artist) = LOWER(?) AND LOWER(album) = LOWER(?)
                """, arguments: [artist, album])
                if !mks.isEmpty { out.append(MBAlbumGroup(artist: artist, album: album, matchKeys: mks)) }
            }
            return out
        }) ?? []
    }

    /// Tracks with no album that still need a recording-level lookup (fallback).
    public func tracksNeedingMBGenres(limit: Int) -> [TrackFeatureRow] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM track_features
                WHERE mb_checked_at IS NULL AND bpm IS NOT NULL
                  AND (album IS NULL OR album = '') AND artist IS NOT NULL AND artist != ''
                LIMIT ?
            """, arguments: [limit]).map(Self.row)
        }) ?? []
    }

    /// Store the genres for a set of tracks and mark them enriched. An empty
    /// `genres` still stamps `mb_checked_at` (so a fruitless lookup isn't retried)
    /// but leaves `mb_genres` NULL.
    public func setMBGenres(matchKeys: [String], genres: [String], checkedAt: String) throws {
        guard !matchKeys.isEmpty else { return }
        let value: String? = genres.isEmpty ? nil
            : (try? JSONSerialization.data(withJSONObject: genres)).flatMap { String(data: $0, encoding: .utf8) }
        try dbQueue.write { db in
            // match_keys per album are few; well under SQLite's 999-variable cap.
            let ph = matchKeys.map { _ in "?" }.joined(separator: ",")
            var args: [DatabaseValueConvertible?] = [value, checkedAt]
            args.append(contentsOf: matchKeys as [DatabaseValueConvertible])
            try db.execute(sql: "UPDATE track_features SET mb_genres = ?, mb_checked_at = ? WHERE match_key IN (\(ph))",
                           arguments: StatementArguments(args))
        }
    }

    public func mbEnrichedCount() -> Int {
        (try? dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(mb_genres) FROM track_features") ?? 0 }) ?? 0
    }

    // MARK: - Deezer genre backfill

    public struct DeezerAlbumGroup: Sendable {
        public let artist: String
        public let album: String
        public let sampleTitle: String   // Deezer search needs artist+TRACK, not artist+album
        public let matchKeys: [String]
    }

    /// Up to `limit` albums that still need a Deezer genre lookup. One track
    /// search (to resolve the Deezer album id) + one album-detail lookup per
    /// album; `matchKeys` is every track on the album so they're all marked done
    /// in one write. Resumable: an interrupted run just re-selects the albums it
    /// didn't reach.
    public func albumsNeedingDeezerGenre(limit: Int) -> [DeezerAlbumGroup] {
        (try? dbQueue.read { db in
            let albums = try Row.fetchAll(db, sql: """
                SELECT artist, album FROM track_features
                WHERE deezer_genre_checked_at IS NULL AND bpm IS NOT NULL
                  AND album IS NOT NULL AND album != '' AND artist IS NOT NULL AND artist != ''
                GROUP BY LOWER(artist), LOWER(album)
                ORDER BY artist, album
                LIMIT ?
            """, arguments: [limit])
            var out: [DeezerAlbumGroup] = []
            for a in albums {
                guard let artist = a["artist"] as String?, let album = a["album"] as String? else { continue }
                let rows = try Row.fetchAll(db, sql: """
                    SELECT match_key, title FROM track_features
                    WHERE LOWER(artist) = LOWER(?) AND LOWER(album) = LOWER(?)
                """, arguments: [artist, album])
                let mks = rows.compactMap { $0["match_key"] as String? }
                let sampleTitle = rows.compactMap { $0["title"] as String? }.first { !$0.isEmpty } ?? ""
                if !mks.isEmpty, !sampleTitle.isEmpty {
                    out.append(DeezerAlbumGroup(artist: artist, album: album, sampleTitle: sampleTitle, matchKeys: mks))
                }
            }
            return out
        }) ?? []
    }

    /// Store Deezer genres for a set of tracks and mark them checked. An empty
    /// `genres` still stamps `deezer_genre_checked_at` (so a fruitless lookup
    /// isn't retried) but leaves `deezer_genres` NULL.
    public func setDeezerGenres(matchKeys: [String], genres: [String], checkedAt: String) throws {
        guard !matchKeys.isEmpty else { return }
        let value: String? = genres.isEmpty ? nil
            : (try? JSONSerialization.data(withJSONObject: genres)).flatMap { String(data: $0, encoding: .utf8) }
        try dbQueue.write { db in
            let ph = matchKeys.map { _ in "?" }.joined(separator: ",")
            var args: [DatabaseValueConvertible?] = [value, checkedAt]
            args.append(contentsOf: matchKeys as [DatabaseValueConvertible])
            try db.execute(sql: "UPDATE track_features SET deezer_genres = ?, deezer_genre_checked_at = ? WHERE match_key IN (\(ph))",
                           arguments: StatementArguments(args))
        }
    }

    public func deezerGenreEnrichedCount() -> Int {
        (try? dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(deezer_genres) FROM track_features") ?? 0 }) ?? 0
    }

    public func deezerGenreCheckedCount() -> Int {
        (try? dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(deezer_genre_checked_at) FROM track_features") ?? 0 }) ?? 0
    }

    /// One artist whose tracks still lack genres after the album + recording passes.
    public struct MBArtistGroup: Sendable {
        public let artist: String
        public let matchKeys: [String]
    }

    /// Up to `limit` artists whose analyzed tracks were checked (album/recording)
    /// but got no genres, and haven't had the artist-level fallback tried yet. One
    /// MB lookup per artist covers all their genre-less tracks. Resumable via
    /// `mb_artist_checked_at`; re-runs over the existing checked-but-empty backlog.
    public func artistsNeedingMBGenres(limit: Int) -> [MBArtistGroup] {
        (try? dbQueue.read { db in
            let artists = try Row.fetchAll(db, sql: """
                SELECT artist FROM track_features
                WHERE mb_genres IS NULL AND mb_checked_at IS NOT NULL AND mb_artist_checked_at IS NULL
                  AND bpm IS NOT NULL AND artist IS NOT NULL AND artist != ''
                GROUP BY LOWER(artist)
                ORDER BY artist
                LIMIT ?
            """, arguments: [limit])
            var out: [MBArtistGroup] = []
            for a in artists {
                guard let artist = a["artist"] as String? else { continue }
                let mks = try String.fetchAll(db, sql: """
                    SELECT match_key FROM track_features
                    WHERE LOWER(artist) = LOWER(?) AND mb_genres IS NULL AND mb_artist_checked_at IS NULL
                """, arguments: [artist])
                if !mks.isEmpty { out.append(MBArtistGroup(artist: artist, matchKeys: mks)) }
            }
            return out
        }) ?? []
    }

    /// Store artist-level genres for a set of tracks and mark the artist fallback
    /// attempted. An empty `genres` still stamps `mb_artist_checked_at` (so a
    /// fruitless lookup isn't retried) but leaves `mb_genres` NULL.
    public func setArtistMBGenres(matchKeys: [String], genres: [String], checkedAt: String) throws {
        guard !matchKeys.isEmpty else { return }
        let value: String? = genres.isEmpty ? nil
            : (try? JSONSerialization.data(withJSONObject: genres)).flatMap { String(data: $0, encoding: .utf8) }
        try dbQueue.write { db in
            for chunk in stride(from: 0, to: matchKeys.count, by: 400).map({ Array(matchKeys[$0..<min($0 + 400, matchKeys.count)]) }) {
                let ph = chunk.map { _ in "?" }.joined(separator: ",")
                var args: [DatabaseValueConvertible?] = [value, checkedAt]
                args.append(contentsOf: chunk as [DatabaseValueConvertible])
                try db.execute(sql: "UPDATE track_features SET mb_genres = ?, mb_artist_checked_at = ? WHERE match_key IN (\(ph))",
                               arguments: StatementArguments(args))
            }
        }
    }

    // MARK: - Deezer popularity enrichment

    /// One analyzed track still needing a popularity lookup.
    public struct PopularityTrack: Sendable {
        public let matchKey: String
        public let artist: String
        public let title: String
    }

    /// Up to `limit` analyzed tracks whose popularity hasn't been looked up yet.
    /// One Deezer search per track; resumable — an interrupted run just re-selects
    /// the tracks it didn't reach (rows with `popularity_checked_at IS NULL`).
    public func tracksNeedingPopularity(limit: Int) -> [PopularityTrack] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT match_key, artist, title FROM track_features
                WHERE popularity_checked_at IS NULL AND bpm IS NOT NULL
                  AND artist IS NOT NULL AND artist != '' AND title IS NOT NULL AND title != ''
                LIMIT ?
            """, arguments: [limit])
        })?.compactMap { r in
            guard let mk = r["match_key"] as String?,
                  let artist = r["artist"] as String?, let title = r["title"] as String? else { return nil }
            return PopularityTrack(matchKey: mk, artist: artist, title: title)
        } ?? []
    }

    /// Store a track's popularity and mark it looked up. A nil `popularity` still
    /// stamps `popularity_checked_at` (so a fruitless lookup isn't retried) but
    /// leaves the value NULL.
    public func setPopularity(matchKey: String, popularity: Int?, checkedAt: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE track_features SET popularity = ?, popularity_checked_at = ? WHERE match_key = ?",
                           arguments: [popularity, checkedAt, matchKey])
        }
    }

    /// Tracks looked up (incl. fruitless) — drives the enricher's progress UI.
    public func popularityCheckedCount() -> Int {
        (try? dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(popularity_checked_at) FROM track_features") ?? 0 }) ?? 0
    }

    /// Tracks that got a non-NULL popularity value.
    public func popularityCount() -> Int {
        (try? dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(popularity) FROM track_features") ?? 0 }) ?? 0
    }

    public func mbCheckedCount() -> Int {
        (try? dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(mb_checked_at) FROM track_features") ?? 0 }) ?? 0
    }

    // MARK: - Dataset-sidecar import (MusicMoveArr)

    /// One analyzed track still needing a sidecar-match. Mirrors `PopularityTrack`.
    public struct DatasetTrack: Sendable {
        public let matchKey: String
        public let artist: String
        public let title: String
        public let album: String?
    }

    /// Up to `limit` tracks not yet matched against the dataset sidecar
    /// (`dataset_checked_at IS NULL`). Resumable, like the other enrichers.
    public func tracksNeedingDatasetCheck(limit: Int) -> [DatasetTrack] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT match_key, artist, title, album FROM track_features
                WHERE dataset_checked_at IS NULL
                  AND artist IS NOT NULL AND artist != '' AND title IS NOT NULL AND title != ''
                LIMIT ?
            """, arguments: [limit])
        })?.compactMap { r in
            guard let mk = r["match_key"] as String?,
                  let artist = r["artist"] as String?, let title = r["title"] as String? else { return nil }
            return DatasetTrack(matchKey: mk, artist: artist, title: title, album: r["album"])
        } ?? []
    }

    /// Store one track's sidecar match and stamp `dataset_checked_at`. All-nil
    /// (no match) still stamps the marker. Existing values are never overwritten
    /// by NULL (COALESCE); `popularity` is only filled when the API enricher
    /// hasn't set it yet (the dump's rank is the same metric, but a fresh API
    /// value beats a quarterly snapshot).
    public func setDatasetIdentity(matchKey: String, isrc: String?, recordingMbid: String?,
                                   deezerBpm: Double?, deezerGain: Double?, popularity: Int?,
                                   albumUpc: String? = nil, label: String? = nil,
                                   releaseDate: String? = nil, explicit: Bool? = nil,
                                   checkedAt: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE track_features SET
                    isrc = COALESCE(?, isrc),
                    recording_mbid = COALESCE(?, recording_mbid),
                    deezer_bpm = COALESCE(?, deezer_bpm),
                    deezer_gain = COALESCE(?, deezer_gain),
                    popularity = COALESCE(popularity, ?),
                    album_upc = COALESCE(?, album_upc),
                    label = COALESCE(?, label),
                    release_date = COALESCE(?, release_date),
                    explicit = COALESCE(?, explicit),
                    dataset_checked_at = ?
                WHERE match_key = ?
            """, arguments: [isrc, recordingMbid, deezerBpm, deezerGain, popularity,
                             albumUpc, label, releaseDate, explicit.map { $0 ? 1 : 0 },
                             checkedAt, matchKey])
        }
    }

    /// Rows matched against the sidecar (incl. "no match") — progress meter.
    public func datasetCheckedCount() -> Int {
        (try? dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(dataset_checked_at) FROM track_features") ?? 0 }) ?? 0
    }

    /// Rows that got an ISRC — the identity yield of the import.
    public func isrcCount() -> Int {
        (try? dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(isrc) FROM track_features") ?? 0 }) ?? 0
    }

    // MARK: - Loudness backfill (F3)

    /// One analyzed track still needing its perceptual loudness computed. Carries
    /// the on-disk path + mtime so the backfill can decode the same excerpt a live
    /// analysis would.
    public struct LoudnessTrack: Sendable {
        public let matchKey: String
        public let filePath: String
        public let mtime: Double
    }

    /// Up to `limit` analyzed tracks whose loudness hasn't been computed yet.
    /// Resumable: rows the backfill already attempted carry `loudness_checked_at`
    /// (even a failed decode), so an interrupted run continues where it left off and
    /// an unreadable file is never retried in a loop. Freshly-analyzed rows already
    /// have `loudness` set, so they're excluded up front.
    public func tracksNeedingLoudness(limit: Int) -> [LoudnessTrack] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT match_key, file_path, file_mtime FROM track_features
                WHERE loudness IS NULL AND loudness_checked_at IS NULL
                  AND bpm IS NOT NULL AND file_path IS NOT NULL AND file_path != ''
                LIMIT ?
            """, arguments: [limit])
        })?.compactMap { r in
            guard let mk = r["match_key"] as String?, let p = r["file_path"] as String? else { return nil }
            return LoudnessTrack(matchKey: mk, filePath: p, mtime: r["file_mtime"] as Double? ?? 0)
        } ?? []
    }

    /// Store a track's loudness and mark it attempted. A nil `loudness` (decode
    /// failed) still stamps `loudness_checked_at` so the file isn't re-decoded.
    public func setLoudness(matchKey: String, loudness: Double?, checkedAt: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE track_features SET loudness = ?, loudness_checked_at = ? WHERE match_key = ?",
                           arguments: [loudness, checkedAt, matchKey])
        }
    }

    /// Tracks that have a non-NULL loudness value — drives the backfill progress UI.
    public func loudnessCount() -> Int {
        (try? dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(loudness) FROM track_features") ?? 0 }) ?? 0
    }

    /// Distinct genre names appearing across all enriched tracks — the set whose
    /// parents are worth resolving (we don't fetch relations for the ~2000 genres
    /// nobody in this library uses).
    public func genresInUse() -> Set<String> {
        let rows = (try? dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT mb_genres FROM track_features WHERE mb_genres IS NOT NULL")
        }) ?? []
        var set = Set<String>()
        for s in rows {
            if let d = s.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: d) as? [String] {
                for g in arr { set.insert(g) }
            }
        }
        return set
    }

    // MARK: - Genre taxonomy

    /// Upsert the flat genre vocabulary (name + MBID), leaving `parent` untouched.
    public func upsertGenres(_ nodes: [MusicBrainzClient.GenreNode]) throws {
        guard !nodes.isEmpty else { return }
        try dbQueue.write { db in
            for n in nodes {
                try db.execute(sql: """
                    INSERT INTO genre_taxonomy (genre, mbid) VALUES (?, ?)
                    ON CONFLICT(genre) DO UPDATE SET mbid = excluded.mbid
                """, arguments: [n.name, n.mbid])
            }
        }
    }

    public func setGenreParent(genre: String, parent: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO genre_taxonomy (genre, parent) VALUES (?, ?)
                ON CONFLICT(genre) DO UPDATE SET parent = excluded.parent
            """, arguments: [genre, parent])
        }
    }

    public func genreMBID(_ genre: String) -> String? {
        (try? dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT mbid FROM genre_taxonomy WHERE genre = ?", arguments: [genre])
        }) ?? nil
    }

    /// Of `names`, the genres whose parent relation hasn't been resolved yet —
    /// no taxonomy row, or `parent IS NULL`. Roots are stamped with an empty
    /// string (`setGenreParent("")`) so they count as resolved and aren't
    /// re-queried every run.
    public func unresolvedParentGenres(_ names: Set<String>) -> [String] {
        guard !names.isEmpty else { return [] }
        let resolved = Set((try? dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT genre FROM genre_taxonomy WHERE parent IS NOT NULL")
        }) ?? [])
        return names.filter { !resolved.contains($0) }
    }

    public func taxonomyCount() -> Int {
        (try? dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM genre_taxonomy") ?? 0 }) ?? 0
    }

    /// Whether the full MusicBrainz genre vocabulary has been fetched COMPLETELY at
    /// least once. Until it has, `buildTaxonomy` must not treat a genre missing
    /// from `genre_taxonomy` as a free-text root — it may simply live on a page a
    /// transient failure skipped. Replaces the old `taxonomyCount() == 0` guard,
    /// which let one successful page declare the whole vocabulary done.
    public func taxonomyComplete() -> Bool {
        let v = (try? dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM analyzer_meta WHERE key = 'taxonomy_complete'")
        }) ?? nil
        return v == "1"
    }

    public func markTaxonomyComplete() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO analyzer_meta (key, value) VALUES ('taxonomy_complete', '1')
                ON CONFLICT(key) DO UPDATE SET value = '1'
            """)
        }
    }

    /// Clear provisional root markers (`parent = ''`) so they're re-resolved. Run
    /// once when the vocabulary first becomes complete: a genre stamped as a root
    /// by an earlier *incomplete* run may actually be a subgenre whose parent lived
    /// on a page that hadn't been fetched yet. Resetting costs at most one MB
    /// relation lookup per current root and heals an already-corrupted tree without
    /// a manual DB wipe.
    public func resetProvisionalRoots() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE genre_taxonomy SET parent = NULL WHERE parent = ''")
        }
    }

    /// The whole genre tree as `[{genre, parent?, mbid?}]` for the `/genres`
    /// endpoint. Only genres that have a parent OR appear in the library matter
    /// to clients, but the vocabulary is small (~2000) so we serve it whole.
    public func taxonomyJSON() -> Data {
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT genre, parent, mbid FROM genre_taxonomy")
        }) ?? []
        var arr: [[String: Any]] = []
        arr.reserveCapacity(rows.count)
        for r in rows {
            guard let g = r["genre"] as String? else { continue }
            var o: [String: Any] = ["genre": g]
            if let p = r["parent"] as String? { o["parent"] = p }
            if let m = r["mbid"] as String? { o["mbid"] = m }
            arr.append(o)
        }
        return (try? JSONSerialization.data(withJSONObject: arr)) ?? Data("[]".utf8)
    }

    /// `includeEmbedding` adds the 512-dim vector as base64 (Float32 LE) per
    /// track — large, so off by default; the binary `/embeddings` endpoint is
    /// the preferred bulk path. `moods` + `embedding_model` are always included
    /// (small) and backward-compatible (older clients ignore unknown keys).
    public func exportJSON(includeEmbedding: Bool = false) -> Data {
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT match_key, artist, title, album, year, bpm, bpm_confidence, camelot, key_root, key_mode, energy, duration,
                       tags, moods, attributes, mb_genres, popularity, loudness, isrc, recording_mbid, deezer_bpm,
                       album_upc, label, release_date, explicit, deezer_genres, embedding_model\(includeEmbedding ? ", embedding" : "")
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
                "camelot": r["camelot"] as String? ?? "",
                "key_root": r["key_root"] as String? ?? "",
                "key_mode": r["key_mode"] as String? ?? "",
                "energy": r["energy"] as Double? ?? 0,
                "duration": r["duration"] as Double? ?? 0,
            ]
            if let year = r["year"] as Int?, year > 0 { obj["year"] = year }
            // Only emit when actually measured: a pre-column NULL must read as
            // "unknown", not as 0.0 (which the flow sequencer treats as lowest
            // tempo-confidence and wrongly distrusts).
            if let bc = r["bpm_confidence"] as Double? { obj["bpm_confidence"] = bc }
            if let loudness = r["loudness"] as Double? { obj["loudness"] = loudness }
            if let tags = r["tags"] as String? { obj["tags"] = tags }
            // MusicBrainz genres as an actual array (the app parses it directly).
            if let mbg = r["mb_genres"] as String?, let d = mbg.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: d) as? [String], !arr.isEmpty {
                obj["mb_genres"] = arr
            }
            if let moods = r["moods"] as String? { obj["moods"] = moods }
            if let attributes = r["attributes"] as String? { obj["attributes"] = attributes }
            if let pop = r["popularity"] as Int?, pop > 0 { obj["popularity"] = pop }
            if let isrc = r["isrc"] as String?, !isrc.isEmpty { obj["isrc"] = isrc }
            if let mbid = r["recording_mbid"] as String?, !mbid.isEmpty { obj["recording_mbid"] = mbid }
            if let dbpm = r["deezer_bpm"] as Double?, dbpm > 0 { obj["deezer_bpm"] = dbpm }
            if let upc = r["album_upc"] as String?, !upc.isEmpty { obj["album_upc"] = upc }
            if let label = r["label"] as String?, !label.isEmpty { obj["label"] = label }
            if let rd = r["release_date"] as String?, !rd.isEmpty { obj["release_date"] = rd }
            if let explicit = r["explicit"] as Int? { obj["explicit"] = explicit != 0 }
            if let dg = r["deezer_genres"] as String?, let d = dg.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: d) as? [String], !arr.isEmpty {
                obj["deezer_genres"] = arr
            }
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
            loudness: r["loudness"],
            embedding: (r["embedding"] as Data?).map(FeatureStore.floats),
            embeddingModel: r["embedding_model"], moods: r["moods"], attributes: r["attributes"]
        )
    }
}
