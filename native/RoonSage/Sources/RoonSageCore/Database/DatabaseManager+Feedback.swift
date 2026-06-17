import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Track feedback (like / dislike)

    /// One like/dislike verdict, keyed by content `match_key` so it joins the
    /// analyzed library and survives resyncs. Codable so the server-of-record can
    /// hand the full set to a thin client over `/feedback`.
    public struct FeedbackEntry: Sendable, Codable {
        public var matchKey: String
        public var title: String?
        public var artist: String?
        public var kind: String        // "like" | "dislike"
        public init(matchKey: String, title: String?, artist: String?, kind: String) {
            self.matchKey = matchKey; self.title = title; self.artist = artist; self.kind = kind
        }
    }

    /// Record (or replace) a verdict for one track. Latest verdict wins.
    public func setFeedback(matchKey: String, title: String?, artist: String?, kind: String) async throws {
        guard !matchKey.isEmpty else { return }
        let iso = Self.isoFormatter.string(from: Date())
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO track_feedback (match_key, title, artist, kind, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(match_key) DO UPDATE SET
                    title = excluded.title, artist = excluded.artist,
                    kind = excluded.kind, updated_at = excluded.updated_at
            """, arguments: [matchKey, title, artist, kind, iso])
        }
    }

    /// Remove a verdict (un-like / un-dislike).
    public func clearFeedback(matchKey: String) async throws {
        guard !matchKey.isEmpty else { return }
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM track_feedback WHERE match_key = ?", arguments: [matchKey])
        }
    }

    /// Every verdict, newest first.
    public func allFeedback() async throws -> [FeedbackEntry] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT match_key, title, artist, kind
                FROM track_feedback ORDER BY updated_at DESC
            """)
            return rows.map {
                FeedbackEntry(
                    matchKey: $0["match_key"] as String? ?? "",
                    title:    $0["title"],
                    artist:   $0["artist"],
                    kind:     $0["kind"] as String? ?? ""
                )
            }
        }
    }
}
