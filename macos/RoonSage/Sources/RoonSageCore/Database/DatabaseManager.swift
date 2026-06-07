import Foundation
import GRDB

/// Manages the GRDB DatabasePool with WAL mode and schema migrations.
/// Thread-safe; GRDB's DatabasePool handles concurrent reads natively.
public final class DatabaseManager: Sendable {

    public let pool: DatabasePool

    public init(url: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
        }
        let p = try DatabasePool(path: url.path, configuration: config)
        pool = p
        try Schema.migrate(p)
    }

    // MARK: - Track queries

    public func upsertTrack(_ record: TrackRecord) throws {
        try pool.write { db in
            try record.save(db)
        }
    }

    public func upsertTracks(_ records: [TrackRecord]) throws {
        try pool.write { db in
            for record in records {
                try record.save(db)
            }
        }
    }

    public func trackCount() throws -> Int {
        try pool.read { db in
            try TrackRecord.fetchCount(db)
        }
    }

    public func searchTracks(query: String, limit: Int = 200) throws -> [TrackRecord] {
        try pool.read { db in
            if query.isEmpty {
                return try TrackRecord
                    .order(Column("title"))
                    .limit(limit)
                    .fetchAll(db)
            }
            let pattern = "%\(query)%"
            return try TrackRecord
                .filter(
                    Column("title").like(pattern) ||
                    Column("artist").like(pattern) ||
                    Column("album").like(pattern)
                )
                .order(Column("title"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func clearTracks() throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM tracks")
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
