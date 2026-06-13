import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Resumable sync (album checkpoints)
    //
    // A sync run is identified by a monotonically increasing generation.
    // Every completed album is checkpointed under that generation; if the run
    // is interrupted (screen lock / app suspend kills the Roon connection),
    // the next run *resumes* the same generation and skips checkpointed
    // albums. Stale rows are only deleted after a fully completed walk —
    // an interrupted sync never leaves a half-empty library.

    public struct SyncRun: Sendable {
        public var generation: Int
        /// True when this run continues an interrupted one.
        public var resumed: Bool
        /// Fingerprints of albums already completed in this generation.
        public var completedAlbums: Set<String>
    }

    /// Start a sync run: resume the in-progress generation if one was
    /// interrupted, otherwise open a fresh generation (which re-walks every
    /// album — required after match_key-resetting migrations).
    public func beginSyncRun() throws -> SyncRun {
        try pool.write { db in
            let inProgress = try String.fetchOne(
                db, sql: "SELECT value FROM sync_state WHERE key='sync_in_progress'") == "1"
            let current = Int(try String.fetchOne(
                db, sql: "SELECT value FROM sync_state WHERE key='sync_generation'") ?? "0") ?? 0

            if inProgress, current > 0 {
                let done = try String.fetchAll(
                    db, sql: "SELECT fingerprint FROM sync_album_checkpoints WHERE generation = ?",
                    arguments: [current])
                return SyncRun(generation: current, resumed: !done.isEmpty, completedAlbums: Set(done))
            }

            let next = current + 1
            try Self.setState(db, "sync_generation", "\(next)")
            try Self.setState(db, "sync_in_progress", "1")
            return SyncRun(generation: next, resumed: false, completedAlbums: [])
        }
    }

    /// Atomically replace one album's rows and checkpoint it. `append: true`
    /// skips the delete — used when the same fingerprint occurs twice in the
    /// album list (two editions with identical title/artist/year) so the
    /// second edition doesn't wipe the first.
    public func replaceAlbumTracks(
        _ records: [TrackRecord],
        albumTitle: String,
        fingerprint: String,
        generation: Int,
        append: Bool = false
    ) throws {
        try pool.write { db in
            if !append {
                // Old-session rows of this album (item_keys differ, so the id
                // upsert can't dedupe them) + pre-v10 legacy rows by title.
                try db.execute(
                    sql: "DELETE FROM tracks WHERE album_fp = ? OR (album_fp IS NULL AND album = ?)",
                    arguments: [fingerprint, albumTitle])
            }
            let chunk = Self.rowsPerChunk(columns: 10)
            var start = 0
            while start < records.count {
                let slice = records[start..<min(start + chunk, records.count)]
                let placeholders = slice.map { _ in "(?,?,?,?,?,?,?,?,?,?)" }.joined(separator: ",")
                let sql = """
                    INSERT INTO tracks
                      (id, title, artist, album, album_key, year, is_live, match_key, image_key, album_fp)
                    VALUES \(placeholders)
                    ON CONFLICT(id) DO UPDATE SET
                      title=excluded.title, artist=excluded.artist, album=excluded.album,
                      album_key=excluded.album_key, year=excluded.year, is_live=excluded.is_live,
                      match_key=excluded.match_key, image_key=excluded.image_key,
                      album_fp=excluded.album_fp
                """
                var args: [DatabaseValueConvertible?] = []
                args.reserveCapacity(slice.count * 10)
                for r in slice {
                    args.append(contentsOf: [r.id, r.title, r.artist, r.album, r.albumKey,
                                             r.year, r.isLive, r.matchKey, r.imageKey,
                                             fingerprint] as [DatabaseValueConvertible?])
                }
                try db.execute(sql: sql, arguments: StatementArguments(args))
                start += chunk
            }
            try db.execute(
                sql: """
                    INSERT INTO sync_album_checkpoints (fingerprint, generation) VALUES (?,?)
                    ON CONFLICT(fingerprint) DO UPDATE SET generation=excluded.generation
                """,
                arguments: [fingerprint, generation])
        }
    }

    /// Close out a fully completed walk: drop rows of albums that no longer
    /// exist in Roon (no checkpoint this generation), prune old-generation
    /// checkpoints, and clear the in-progress flag so the next sync starts a
    /// fresh generation.
    ///
    /// `pruneStale: false` skips the destructive delete. Used when albums
    /// failed to browse during the walk: those albums have no checkpoint this
    /// generation, so pruning would silently delete their (still valid) rows —
    /// a flaky connection must never shrink the library.
    public func finishSyncRun(generation: Int, pruneStale: Bool = true) throws {
        try pool.write { db in
            if pruneStale {
                try db.execute(
                    sql: """
                        DELETE FROM tracks WHERE album_fp IS NULL OR album_fp NOT IN
                          (SELECT fingerprint FROM sync_album_checkpoints WHERE generation = ?)
                    """,
                    arguments: [generation])
            }
            try db.execute(
                sql: "DELETE FROM sync_album_checkpoints WHERE generation < ?",
                arguments: [generation])
            try Self.setState(db, "sync_in_progress", "0")
        }
    }

    /// Insert/replace up to 25 albums in a single WAL transaction. Same semantics
    /// as `replaceAlbumTracks` but amortises fsync cost over the whole batch.
    public struct AlbumBatchItem: Sendable {
        public var records: [TrackRecord]
        public var albumTitle: String
        public var fingerprint: String
        public var generation: Int
        public var append: Bool
        public init(records: [TrackRecord], albumTitle: String, fingerprint: String, generation: Int, append: Bool) {
            self.records = records; self.albumTitle = albumTitle
            self.fingerprint = fingerprint; self.generation = generation; self.append = append
        }
    }

    public func replaceAlbumBatch(_ items: [AlbumBatchItem]) throws {
        guard !items.isEmpty else { return }
        try pool.write { db in
            let chunk = Self.rowsPerChunk(columns: 10)
            for item in items {
                if !item.append {
                    try db.execute(
                        sql: "DELETE FROM tracks WHERE album_fp = ? OR (album_fp IS NULL AND album = ?)",
                        arguments: [item.fingerprint, item.albumTitle])
                }
                var start = 0
                while start < item.records.count {
                    let slice = item.records[start..<min(start + chunk, item.records.count)]
                    let placeholders = slice.map { _ in "(?,?,?,?,?,?,?,?,?,?)" }.joined(separator: ",")
                    let sql = """
                        INSERT INTO tracks
                          (id, title, artist, album, album_key, year, is_live, match_key, image_key, album_fp)
                        VALUES \(placeholders)
                        ON CONFLICT(id) DO UPDATE SET
                          title=excluded.title, artist=excluded.artist, album=excluded.album,
                          album_key=excluded.album_key, year=excluded.year, is_live=excluded.is_live,
                          match_key=excluded.match_key, image_key=excluded.image_key,
                          album_fp=excluded.album_fp
                    """
                    var args: [DatabaseValueConvertible?] = []
                    args.reserveCapacity(slice.count * 10)
                    for r in slice {
                        args.append(contentsOf: [r.id, r.title, r.artist, r.album, r.albumKey,
                                                 r.year, r.isLive, r.matchKey, r.imageKey,
                                                 item.fingerprint] as [DatabaseValueConvertible?])
                    }
                    try db.execute(sql: sql, arguments: StatementArguments(args))
                    start += chunk
                }
                try db.execute(
                    sql: """
                        INSERT INTO sync_album_checkpoints (fingerprint, generation) VALUES (?,?)
                        ON CONFLICT(fingerprint) DO UPDATE SET generation=excluded.generation
                    """,
                    arguments: [item.fingerprint, item.generation])
            }
        }
    }

    private static func setState(_ db: Database, _ key: String, _ value: String) throws {
        try db.execute(
            sql: "INSERT INTO sync_state (key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            arguments: [key, value])
    }
}
