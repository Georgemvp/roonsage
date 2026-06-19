import Accelerate
import Foundation

/// The user's "musical centre of gravity" in CLAP embedding space — a single
/// recency-weighted vector that every smart station can lean toward, so a radio
/// is never just "near the seed" but "near the seed, *the way you like it*".
///
/// Each played track contributes its embedding weighted by
/// `log(1 + playCount) · exp(−ageDays / halfLife)`, so heavy rotation matters but
/// recent listening matters more (your taste this season outweighs three years
/// ago). Thumbed-up tracks get a flat bonus on top. The sum is L2-normalized into
/// a query-usable direction; `nil` when there's no history to learn from.
public enum TasteVector {

    /// Half-life of the recency decay, in days. ~4 months: last season dominates,
    /// but older favourites still register.
    static let halfLifeDays = 120.0
    static let likeBonus = 2.0

    public static func compute(
        stats: [(matchKey: String, count: Int, lastPlayed: String)],
        likedKeys: Set<String>,
        index: VectorIndex,
        now: Date = Date()
    ) -> [Float]? {
        guard !stats.isEmpty || !likedKeys.isEmpty else { return nil }

        // content key → embedding (rows are already L2-normalized in the index).
        var embByKey = [String: [Float]](minimumCapacity: index.tracks.count)
        for t in index.tracks where !t.matchKey.isEmpty {
            if let e = index.embedding(forId: t.id) { embByKey[t.matchKey] = e }
        }
        guard let dim = embByKey.values.first?.count, dim > 0 else { return nil }

        let parser = ISO8601DateFormatter()
        var acc = [Float](repeating: 0, count: dim)
        var any = false

        func add(_ emb: [Float], _ w: Float) {
            guard w > 0 else { return }
            var ws = w
            var scaled = [Float](repeating: 0, count: dim)
            vDSP_vsmul(emb, 1, &ws, &scaled, 1, vDSP_Length(dim))
            vDSP_vadd(acc, 1, scaled, 1, &acc, 1, vDSP_Length(dim))
            any = true
        }

        for s in stats {
            guard let emb = embByKey[s.matchKey] else { continue }
            let recency: Double
            if let d = parser.date(from: s.lastPlayed) {
                let ageDays = max(0, now.timeIntervalSince(d) / 86_400)
                recency = exp(-ageDays / halfLifeDays)
            } else {
                recency = 0.5   // unknown timestamp → middling weight
            }
            let weight = log(1 + Double(s.count)) * recency
            add(emb, Float(weight))
        }
        // Explicit likes are a strong "this is me" signal, regardless of plays.
        for key in likedKeys {
            if let emb = embByKey[key] { add(emb, Float(likeBonus)) }
        }

        guard any else { return nil }
        return VectorIndex.normalized(acc)
    }
}
