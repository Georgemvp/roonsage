import Foundation
import GRDB

/// Manages the GRDB DatabasePool with WAL mode and schema migrations.
/// Thread-safe; GRDB's DatabasePool handles concurrent reads natively.
public final class DatabaseManager: Sendable {

    public let pool: DatabasePool

    /// Shared ISO8601 formatter — constructing one per call is expensive and
    /// `logListen` fires on every track change. Thread-safe for formatting.
    static let isoFormatter = ISO8601DateFormatter()

    public init(url: URL) throws {
        var config = Configuration()
        // A contended write (e.g. share-server export overlapping a sync
        // batch) should wait briefly instead of throwing SQLITE_BUSY.
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
        }
        let p = try DatabasePool(path: url.path, configuration: config)
        pool = p
        try Schema.migrate(p)
    }

}
