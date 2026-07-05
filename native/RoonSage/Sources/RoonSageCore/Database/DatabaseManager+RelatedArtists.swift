import Foundation
import GRDB

// MARK: - Related artists (Deezer "fans also like" cache)

extension DatabaseManager {

    /// Replace the cached related-artist set for one seed artist. An empty
    /// `related` list writes only the negative-cache sentinel, so a
    /// Deezer-unknown artist isn't re-queried every radio build.
    public func upsertRelatedArtists(artistKey: String, related: [String]) async throws {
        let key = artistKey.lowercased()
        guard !key.isEmpty else { return }
        let iso = Self.isoFormatter.string(from: Date())
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM related_artists WHERE artist_key = ?", arguments: [key])
            if related.isEmpty {
                try db.execute(
                    sql: "INSERT INTO related_artists (artist_key, related, rank, fetched_at) VALUES (?, '', 0, ?)",
                    arguments: [key, iso])
                return
            }
            for (i, name) in related.enumerated() {
                let n = name.lowercased().trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { continue }
                try db.execute(sql: """
                    INSERT INTO related_artists (artist_key, related, rank, fetched_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(artist_key, related) DO UPDATE SET rank=excluded.rank, fetched_at=excluded.fetched_at
                """, arguments: [key, n, i, iso])
            }
        }
    }

    /// The cached related artists (lowercased, rank order) for one seed artist,
    /// or nil when never fetched / stale (older than `maxAgeDays`) — nil tells
    /// the caller to (re)fetch. A negative-cache sentinel returns `[]` fresh.
    public func relatedArtists(for artistKey: String, maxAgeDays: Int = 30) async throws -> [String]? {
        let key = artistKey.lowercased()
        guard !key.isEmpty else { return [] }
        let cutoff = Self.isoFormatter.string(from: Date().addingTimeInterval(-Double(maxAgeDays) * 86_400))
        return try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT related, fetched_at FROM related_artists WHERE artist_key = ? ORDER BY rank
            """, arguments: [key])
            guard !rows.isEmpty else { return nil }
            let newest = rows.compactMap { $0["fetched_at"] as String? }.max() ?? ""
            guard newest >= cutoff else { return nil }   // stale → refetch
            return rows.compactMap { r -> String? in
                let name: String = r["related"] ?? ""
                return name.isEmpty ? nil : name          // drop the sentinel
            }
        }
    }
}
