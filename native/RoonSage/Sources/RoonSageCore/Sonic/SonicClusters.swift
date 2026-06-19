import Accelerate
import Foundation

/// Sonic neighborhoods — k-means over the CLAP embeddings to discover the
/// natural "rooms" in a library (a late-night ambient corner, a peak-time house
/// corner, a singer-songwriter corner…), each becoming its own station. Unlike
/// the genre/mood buckets (which slice on metadata), these emerge purely from how
/// the music *sounds*, so they surface coherent pockets the tags never named.
///
/// Deterministic: farthest-first seeding + argmax assignment (lowest index wins
/// ties), no RNG — so the same library yields the same neighborhoods across runs.
/// Assignment is one `vDSP_mmul` (points · centroidsᵀ) per iteration.
public enum SonicClusters {

    public struct Cluster: Sendable {
        public let id: Int
        public let label: String
        public let memberIds: [String]
        public var size: Int { memberIds.count }
    }

    /// Cluster the embedded tracks. `genresById` (track id → Roon genres) labels
    /// each neighborhood by its dominant genre, falling back to a dominant tag or
    /// mood. Returns clusters sorted largest-first; `[]` when too few embeddings.
    public static func compute(
        tracks: [DatabaseManager.SonicTrack],
        index: VectorIndex,
        genresById: [String: Set<String>],
        maxIters: Int = 12
    ) -> [Cluster] {
        struct Pt { let track: DatabaseManager.SonicTrack; let vec: [Float] }
        let pts: [Pt] = tracks.compactMap { t in
            guard let v = index.embedding(forId: t.id) else { return nil }
            return Pt(track: t, vec: v)
        }
        let n = pts.count
        guard n >= 16 else { return [] }
        let dim = pts[0].vec.count
        // ~√(n/2) neighborhoods, clamped to a UI-sensible 6…20.
        let k = max(6, min(20, Int((Double(n) / 2).squareRoot())))
        guard k >= 2, n > k else { return [] }

        // Flat point matrix (n×dim), row-major — rows are already unit vectors.
        var M = [Float](repeating: 0, count: n * dim)
        for (i, p) in pts.enumerated() { M.replaceSubrange(i * dim..<(i + 1) * dim, with: p.vec) }

        // Farthest-first init: spread the initial centroids so k-means doesn't
        // collapse. Start at point 0, then repeatedly add the point with the
        // largest cosine distance to the nearest chosen centroid.
        var seedRows = [0]
        var minDistToChosen = [Float](repeating: Float.greatestFiniteMagnitude, count: n)
        while seedRows.count < k {
            let last = pts[seedRows.last!].vec
            for i in 0..<n {
                let d = 1 - dot(pts[i].vec, last)
                if d < minDistToChosen[i] { minDistToChosen[i] = d }
            }
            // Pick the farthest (max min-distance); lowest index breaks ties.
            var best = 0; var bestD: Float = -1
            for i in 0..<n where minDistToChosen[i] > bestD { bestD = minDistToChosen[i]; best = i }
            if seedRows.contains(best) { break }
            seedRows.append(best)
        }
        var centroids: [[Float]] = seedRows.map { pts[$0].vec }

        var assign = [Int](repeating: -1, count: n)
        for _ in 0..<maxIters {
            // B (dim×k): B[d*k + c] = centroids[c][d]; scores = M·B (n×k).
            var B = [Float](repeating: 0, count: dim * k)
            for c in 0..<k {
                let cen = centroids[c]
                for d in 0..<dim { B[d * k + c] = cen[d] }
            }
            var scores = [Float](repeating: 0, count: n * k)
            M.withUnsafeBufferPointer { mp in
                B.withUnsafeBufferPointer { bp in
                    scores.withUnsafeMutableBufferPointer { sp in
                        vDSP_mmul(mp.baseAddress!, 1, bp.baseAddress!, 1, sp.baseAddress!, 1,
                                  vDSP_Length(n), vDSP_Length(k), vDSP_Length(dim))
                    }
                }
            }
            var changed = false
            for i in 0..<n {
                let base = i * k
                var best = 0; var bestS = -Float.greatestFiniteMagnitude
                for c in 0..<k where scores[base + c] > bestS { bestS = scores[base + c]; best = c }
                if assign[i] != best { assign[i] = best; changed = true }
            }
            if !changed { break }
            // Recompute centroids = L2-normalized mean of members; keep old if empty.
            var sums = [[Float]](repeating: [Float](repeating: 0, count: dim), count: k)
            var counts = [Int](repeating: 0, count: k)
            for i in 0..<n {
                let c = assign[i]; counts[c] += 1
                sums[c].withUnsafeMutableBufferPointer { sp in
                    pts[i].vec.withUnsafeBufferPointer { vp in
                        vDSP_vadd(sp.baseAddress!, 1, vp.baseAddress!, 1, sp.baseAddress!, 1, vDSP_Length(dim))
                    }
                }
            }
            for c in 0..<k where counts[c] > 0 { centroids[c] = VectorIndex.normalized(sums[c]) }
        }

        var membersByC = [[Int]](repeating: [], count: k)
        for i in 0..<n where assign[i] >= 0 { membersByC[assign[i]].append(i) }

        var out: [Cluster] = []
        for c in 0..<k where !membersByC[c].isEmpty {
            let members = membersByC[c].map { pts[$0].track }
            out.append(Cluster(id: c, label: label(for: members, genresById: genresById, index: c),
                               memberIds: members.map(\.id)))
        }
        return out.sorted { $0.size > $1.size }
    }

    // MARK: - Labeling

    /// Name a neighborhood by its dominant Roon genre (if it covers ≥30% of the
    /// cluster), else dominant analyzer tag, else dominant mood, else a fallback.
    private static func label(
        for members: [DatabaseManager.SonicTrack],
        genresById: [String: Set<String>], index c: Int
    ) -> String {
        let size = max(1, members.count)
        let threshold = max(2, size * 3 / 10)

        // Dominant genre (keep first-seen casing).
        var genreCount: [String: Int] = [:]
        var genreLabel: [String: String] = [:]
        for m in members {
            for g in genresById[m.id] ?? [] {
                let key = g.lowercased()
                guard !key.isEmpty else { continue }
                genreCount[key, default: 0] += 1
                if genreLabel[key] == nil { genreLabel[key] = g }
            }
        }
        if let top = genreCount.max(by: { $0.value < $1.value }), top.value >= threshold {
            return genreLabel[top.key] ?? top.key.capitalized
        }

        // Dominant analyzer tag.
        var tagCount: [String: Int] = [:]
        for m in members { for t in m.tags { tagCount[t.lowercased(), default: 0] += 1 } }
        if let top = tagCount.max(by: { $0.value < $1.value }), top.value >= threshold {
            return top.key.capitalized
        }

        // Dominant mood (argmax per track).
        var moodCount: [String: Int] = [:]
        for m in members {
            if let top = m.moods.max(by: { $0.value < $1.value }), top.value >= 0.3 {
                moodCount[top.key.lowercased(), default: 0] += 1
            }
        }
        if let top = moodCount.max(by: { $0.value < $1.value }) {
            return moodName(top.key)
        }
        return "Sonische buurt \(c + 1)"
    }

    private static func moodName(_ key: String) -> String {
        let map: [String: String] = [
            "happy": "Vrolijk", "sad": "Melancholisch", "relaxed": "Ontspannen",
            "aggressive": "Stevig", "party": "Feestelijk", "danceable": "Dansbaar",
        ]
        return map[key] ?? key.capitalized
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var d: Float = 0
        vDSP_dotpr(a, 1, b, 1, &d, vDSP_Length(min(a.count, b.count)))
        return d
    }
}
