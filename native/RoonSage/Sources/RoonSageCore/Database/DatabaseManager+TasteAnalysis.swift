import Foundation
import GRDB

extension DatabaseManager {
    /// A compact "who you are as a listener" summary, derived from listening
    /// history (time-of-day, genres, decades), and explicit like/dislike
    /// feedback. Codable so a thin client can pull it from the server-of-record
    /// (its own `listening_history` / `track_feedback` are empty).
    public struct TasteAnalysis: Sendable, Codable {
        public struct Count: Sendable, Codable, Identifiable {
            public var label: String
            public var count: Int
            public var id: String { label }
            public init(label: String, count: Int) { self.label = label; self.count = count }
        }
        public var totalPlays: Int
        public var likeCount: Int
        public var dislikeCount: Int
        public var topGenres: [Count]
        public var topDecades: [Count]
        public var partsOfDay: [Count]      // Ochtend / Middag / Avond / Nacht
        public var peakHour: Int            // 0…23, or -1 when there's no history
        public var topLikedArtists: [String]
        public var topDislikedArtists: [String]
    }

    public func tasteAnalysis() async throws -> TasteAnalysis {
        try await pool.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listening_history") ?? 0
            let likeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_feedback WHERE kind='like'") ?? 0
            let dislikeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_feedback WHERE kind='dislike'") ?? 0

            // Genres of what you actually play: join listens to library tracks
            // (by artist+title) → their genres.
            let genreRows = try Row.fetchAll(db, sql: """
                SELECT g.genre AS label, COUNT(*) AS cnt
                FROM listening_history lh
                JOIN tracks t ON LOWER(t.title) = LOWER(lh.title) AND LOWER(t.artist) = LOWER(lh.artist)
                JOIN track_genres g ON g.track_id = t.id
                GROUP BY g.genre ORDER BY cnt DESC LIMIT 6
            """)
            let topGenres = genreRows.map {
                TasteAnalysis.Count(label: $0["label"] as String? ?? "", count: $0["cnt"] as Int? ?? 0)
            }

            let decadeRows = try Row.fetchAll(db, sql: """
                SELECT (t.year/10)*10 AS dec, COUNT(*) AS cnt
                FROM listening_history lh
                JOIN tracks t ON LOWER(t.title) = LOWER(lh.title) AND LOWER(t.artist) = LOWER(lh.artist)
                WHERE t.year IS NOT NULL AND t.year > 1900
                GROUP BY dec ORDER BY cnt DESC LIMIT 5
            """)
            let topDecades = decadeRows.map {
                TasteAnalysis.Count(label: "\($0["dec"] as Int? ?? 0)s", count: $0["cnt"] as Int? ?? 0)
            }

            // Plays per hour → parts of day + peak hour.
            var byHour = [Int](repeating: 0, count: 24)
            let hourRows = try Row.fetchAll(db, sql: """
                SELECT CAST(SUBSTR(played_at, 12, 2) AS INTEGER) AS hr, COUNT(*) AS cnt
                FROM listening_history GROUP BY hr
            """)
            for r in hourRows {
                let h = r["hr"] as Int? ?? 0
                if h >= 0, h < 24 { byHour[h] = r["cnt"] as Int? ?? 0 }
            }
            let buckets: [(String, ClosedRange<Int>)] = [
                ("Ochtend", 6...11), ("Middag", 12...17), ("Avond", 18...23), ("Nacht", 0...5),
            ]
            let partsOfDay = buckets.map { label, range in
                TasteAnalysis.Count(label: label, count: range.reduce(0) { $0 + byHour[$1] })
            }
            let peakHour = total > 0 ? (byHour.enumerated().max { $0.element < $1.element }?.offset ?? -1) : -1

            func feedbackArtists(_ kind: String) throws -> [String] {
                try Row.fetchAll(db, sql: """
                    SELECT artist FROM track_feedback
                    WHERE kind = ? AND artist IS NOT NULL AND artist <> ''
                    GROUP BY artist ORDER BY COUNT(*) DESC, MAX(updated_at) DESC LIMIT 5
                """, arguments: [kind]).compactMap { $0["artist"] as String? }
            }

            return TasteAnalysis(
                totalPlays: total, likeCount: likeCount, dislikeCount: dislikeCount,
                topGenres: topGenres, topDecades: topDecades, partsOfDay: partsOfDay,
                peakHour: peakHour,
                topLikedArtists: try feedbackArtists("like"),
                topDislikedArtists: try feedbackArtists("dislike"))
        }
    }
}
