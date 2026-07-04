import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Bookmarks ("Bewaar voor later" — server-of-record)
    //
    // Wired exactly like favorites: content-derived keys (survive resyncs),
    // server-of-record persistence, GET the whole set for the list view.

    public struct BookmarkEntry: Sendable, Codable, Equatable {
        public var kind: String       // "track" | "album" | "artist"
        public var key: String        // content key (survives resyncs)
        public var title: String?
        public var artist: String?
        public var album: String?
        public init(kind: String, key: String, title: String?, artist: String?, album: String?) {
            self.kind = kind; self.key = key; self.title = title
            self.artist = artist; self.album = album
        }
    }

    public func setBookmark(_ e: BookmarkEntry) async throws {
        guard !e.kind.isEmpty, !e.key.isEmpty else { return }
        let iso = Self.isoFormatter.string(from: Date())
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO bookmarks (kind, key, title, artist, album, created_at) VALUES (?,?,?,?,?,?)
                ON CONFLICT(kind, key) DO UPDATE SET title=excluded.title, artist=excluded.artist, album=excluded.album
                """, arguments: [e.kind, e.key, e.title, e.artist, e.album, iso])
        }
    }

    public func removeBookmark(kind: String, key: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM bookmarks WHERE kind = ? AND key = ?",
                           arguments: [kind, key])
        }
    }

    public func allBookmarks() async throws -> [BookmarkEntry] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT kind, key, title, artist, album FROM bookmarks ORDER BY created_at DESC
                """)
            return rows.map {
                BookmarkEntry(kind: $0["kind"] ?? "", key: $0["key"] ?? "",
                              title: $0["title"], artist: $0["artist"], album: $0["album"])
            }
        }
    }
}
