import Foundation

/// Pure recency-decay scoring for the "forgotten music" discovery axis — a second
/// axis alongside sonic similarity that resurfaces albums by *when you last heard
/// them*, not by how they sound. Higher score = more forgotten = higher priority
/// to suggest. No I/O, fully deterministic — the testable core of
/// `ForgottenMusicService`.
public enum ForgottenScore {
    /// Days after which a played album is ~63% of the way to the recency ceiling.
    static let recencyHalfLifeDays = 180.0
    /// Play-count at which the "you once loved this" bonus is ~63% saturated.
    static let playDepthScale = 8.0

    /// Fixed Gregorian/UTC calendar so "album of the day" resolves to the same
    /// album regardless of the host's timezone — determinism beats local-midnight
    /// alignment for a once-a-day rotation.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()

    /// Forgotten-ness of one album in `[0, 1]`.
    ///
    /// - `lastPlayedAt == nil` (never played here) → `1.0`, the ceiling: a
    ///   never-heard album always outranks any album you've ever played.
    /// - otherwise a saturating recency term in `[0, 0.9)` (older last-play →
    ///   higher), plus a small `[0, 0.1)` bonus for albums you once played a lot,
    ///   so a long-lost favourite edges out a one-off play with the same last-heard
    ///   date. The played total is capped strictly below `1.0`, guaranteeing the
    ///   never-played ceiling is never tied by a played album.
    public static func score(lastPlayedAt: Date?, now: Date = Date(), playCount: Int = 0) -> Double {
        guard let last = lastPlayedAt else { return 1.0 }
        let days = max(0, now.timeIntervalSince(last) / 86_400)   // seconds → days, clamped ≥ 0
        let recency = 0.9 * (1 - exp(-days / recencyHalfLifeDays))
        let depth = 0.1 * (1 - exp(-Double(max(0, playCount)) / playDepthScale))
        return min(0.99, recency + depth)
    }

    /// Deterministic index into a `count`-sized pool for a given calendar day: the
    /// same date always returns the same index, the next day (almost always) a
    /// different one. Seed = day-of-year + year, reduced with a non-negative modulo.
    public static func pickIndex(for date: Date, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let year = calendar.component(.year, from: date)
        let seed = day &+ year
        return ((seed % count) + count) % count   // non-negative modulo (defensive)
    }
}
