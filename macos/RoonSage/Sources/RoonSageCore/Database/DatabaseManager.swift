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

}
