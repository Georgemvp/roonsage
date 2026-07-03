import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Favorites (starred albums / artists — server-of-record)

    public struct FavoriteEntry: Sendable, Codable, Equatable {
        public var kind: String      // "artist" | "album"
        public var key: String       // content key (survives resyncs)
        public var title: String?
        public var artist: String?
        public init(kind: String, key: String, title: String?, artist: String?) {
            self.kind = kind; self.key = key; self.title = title; self.artist = artist
        }
    }

    public func setFavorite(_ e: FavoriteEntry) async throws {
        guard !e.kind.isEmpty, !e.key.isEmpty else { return }
        let iso = Self.isoFormatter.string(from: Date())
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO favorites (kind, key, title, artist, created_at) VALUES (?,?,?,?,?)
                ON CONFLICT(kind, key) DO UPDATE SET title=excluded.title, artist=excluded.artist
                """, arguments: [e.kind, e.key, e.title, e.artist, iso])
        }
    }

    public func removeFavorite(kind: String, key: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM favorites WHERE kind = ? AND key = ?",
                           arguments: [kind, key])
        }
    }

    public func allFavorites() async throws -> [FavoriteEntry] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT kind, key, title, artist FROM favorites ORDER BY created_at DESC
                """)
            return rows.map {
                FavoriteEntry(kind: $0["kind"] ?? "", key: $0["key"] ?? "",
                              title: $0["title"], artist: $0["artist"])
            }
        }
    }
}
