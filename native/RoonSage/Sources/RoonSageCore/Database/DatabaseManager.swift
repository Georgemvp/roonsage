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

    /// Open the database, self-healing from on-disk corruption. The library is a
    /// rebuildable cache, so on a corruption-class error the bad file (plus its
    /// WAL/SHM sidecars) is quarantined and a fresh database is created — a
    /// resync repopulates it. Without this, a corrupt file made the swallowed
    /// `try?` open return nil and the app launched to a permanently empty
    /// library with no error and no recovery.
    public static func open(url: URL) -> DatabaseManager? {
        do {
            return try DatabaseManager(url: url)
        } catch {
            guard isCorruption(error) else {
                Log.error("kon database niet openen: \(error)", category: .db)
                return nil
            }
            Log.error("database corrupt — quarantine + opnieuw aanmaken: \(error)", category: .db)
            quarantine(url)
            do {
                return try DatabaseManager(url: url)
            } catch {
                Log.error("database opnieuw aanmaken mislukt na quarantine: \(error)", category: .db)
                return nil
            }
        }
    }

    /// Corruption-class GRDB errors that warrant recreating the cache.
    private static func isCorruption(_ error: Error) -> Bool {
        guard let dbErr = error as? DatabaseError else { return false }
        let primary = dbErr.resultCode.primaryResultCode
        return primary == .SQLITE_CORRUPT || primary == .SQLITE_NOTADB
    }

    /// Move the database file and its WAL/SHM sidecars aside so a fresh one can
    /// be created. Best-effort: a failed move falls through to a failed reopen.
    private static func quarantine(_ url: URL) {
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: url.path + ".corrupt-\(stamp)" + suffix)
            try? fm.moveItem(at: src, to: dst)
        }
    }

}
