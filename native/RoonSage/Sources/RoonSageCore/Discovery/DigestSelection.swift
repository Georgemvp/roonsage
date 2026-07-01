import Foundation

// MARK: - Weekly digest selection (F12b)
//
// The weekly digest is a highlight reel: the strongest still-PENDING album
// recommendations across every retained batch (not just the newest — daily
// batches are pruned to a rolling window, see `pruneOldBatches`), auto-saved to
// a dated Qobuz playlist so a curated set exists without swiping every card.

public enum DigestSelection {

    /// One pending album recommendation as the digest sees it — decoupled from
    /// `DatabaseManager.RecommendationRow` so ranking stays pure/testable.
    public struct Candidate: Sendable {
        public var dedupKey: String
        public var artist: String
        public var album: String
        public var qobuzAlbumID: String?
        public var score: Double
        public init(dedupKey: String, artist: String, album: String, qobuzAlbumID: String?, score: Double) {
            self.dedupKey = dedupKey; self.artist = artist; self.album = album
            self.qobuzAlbumID = qobuzAlbumID; self.score = score
        }
    }

    /// Dedupe by `dedupKey` (the same album can appear in several retained
    /// batches — keep its highest-scoring occurrence) then take the top `limit`
    /// by score, ties broken alphabetically by album for determinism.
    public static func top(_ candidates: [Candidate], limit: Int) -> [Candidate] {
        guard limit > 0 else { return [] }
        var best: [String: Candidate] = [:]
        for c in candidates {
            if let existing = best[c.dedupKey], existing.score >= c.score { continue }
            best[c.dedupKey] = c
        }
        return best.values
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.album < $1.album }
            .prefix(limit)
            .map { $0 }
    }

    /// ISO-8601 week key ("2026-W27") for `date` — `.yearForWeekOfYear` (not
    /// `.year`) is deliberate: it correctly attributes early-January dates that
    /// fall in the PRIOR year's final week (and December dates that fall in the
    /// NEXT year's week 1) instead of mislabelling the week boundary.
    public static func weekKey(for date: Date) -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let week = cal.component(.weekOfYear, from: date)
        let year = cal.component(.yearForWeekOfYear, from: date)
        return String(format: "%d-W%02d", year, week)
    }
}
