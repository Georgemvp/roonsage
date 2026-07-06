import Accelerate
import Foundation

/// Brute-force cosine k-NN over CLAP embeddings (Track E5d).
///
/// Embeddings are already L2-normalized by the analyzer, so cosine == dot
/// product. A query is one matrix·vector multiply (`vDSP_mmul`) over the whole
/// library — fast enough for tens of thousands of tracks, and no index to keep
/// in sync (HNSW would be overkill here). Built from the tracks that actually
/// carry an embedding; the rest fall back to the rule-based engine.
public struct VectorIndex: Sendable {
    public let dim: Int
    public let tracks: [DatabaseManager.SonicTrack]   // only those with an embedding
    private let matrix: [Float]                       // tracks.count × dim, row-major, L2-normed
    private let idToRow: [String: Int]

    /// nil when fewer than two tracks carry an embedding (nothing to rank).
    public init?(tracks all: [DatabaseManager.SonicTrack]) {
        let withEmb = all.filter { ($0.embedding?.count ?? 0) > 0 }
        guard let d = withEmb.first?.embedding?.count, d > 0 else { return nil }
        let valid = withEmb.filter { $0.embedding?.count == d }
        guard valid.count >= 2 else { return nil }

        var m = [Float](repeating: 0, count: valid.count * d)
        var map = [String: Int](minimumCapacity: valid.count)
        for (i, t) in valid.enumerated() {
            let row = Self.normalized(t.embedding!)
            m.replaceSubrange(i * d..<(i + 1) * d, with: row)
            map[t.id] = i
        }
        self.dim = d
        self.tracks = valid
        self.matrix = m
        self.idToRow = map
    }

    public var count: Int { tracks.count }

    public func embedding(forId id: String) -> [Float]? {
        guard let r = idToRow[id] else { return nil }
        return Array(matrix[r * dim..<(r + 1) * dim])
    }

    public struct Hit: Sendable { public let track: DatabaseManager.SonicTrack; public let score: Float }

    /// k nearest tracks to a query vector (cosine), excluding `excludingIds`.
    public func nearest(to query: [Float], k: Int, excludingIds: Set<String> = []) -> [Hit] {
        guard query.count == dim, count > 0 else { return [] }
        let q = Self.normalized(query)
        var scores = [Float](repeating: 0, count: count)
        // scores(count×1) = matrix(count×dim) · q(dim×1)
        matrix.withUnsafeBufferPointer { mp in
            q.withUnsafeBufferPointer { qp in
                scores.withUnsafeMutableBufferPointer { sp in
                    vDSP_mmul(mp.baseAddress!, 1, qp.baseAddress!, 1, sp.baseAddress!, 1,
                              vDSP_Length(count), 1, vDSP_Length(dim))
                }
            }
        }
        var idx = Array(0..<count)
        if !excludingIds.isEmpty { idx = idx.filter { !excludingIds.contains(tracks[$0].id) } }
        idx.sort { scores[$0] > scores[$1] }
        return idx.prefix(k).map { Hit(track: tracks[$0], score: scores[$0]) }
    }

    /// k nearest to an existing track (by id), excluding the seed itself.
    public func nearest(toId id: String, k: Int) -> [Hit] {
        guard let q = embedding(forId: id) else { return [] }
        return nearest(to: q, k: k, excludingIds: [id])
    }

    /// Mean (recency-weighted if `weights` given) of several tracks' vectors,
    /// L2-normalized — a centroid usable as a query.
    public func centroid(ofIds ids: [String], weights: [Float]? = nil) -> [Float]? {
        let rows = ids.compactMap { idToRow[$0] }
        guard !rows.isEmpty else { return nil }
        var acc = [Float](repeating: 0, count: dim)
        // Accumulate wᵢ·rowᵢ into acc in place (vsma: D = A·B + C with C == D), so
        // the hot loop allocates no per-source scratch buffer.
        acc.withUnsafeMutableBufferPointer { ap in
            matrix.withUnsafeBufferPointer { mp in
                for (j, r) in rows.enumerated() {
                    var w = weights?[safe: j] ?? 1
                    vDSP_vsma(mp.baseAddress! + r * dim, 1, &w, ap.baseAddress!, 1,
                              ap.baseAddress!, 1, vDSP_Length(dim))
                }
            }
        }
        return Self.normalized(acc)
    }

    /// Library-calibrated similarity statistics (LMS-style adaptive threshold):
    /// sample tracks, measure each one's *nearest-neighbour* cosine similarity,
    /// return mean + standard deviation. "Similar" then means "within a few σ
    /// of what neighbours in THIS library look like" instead of a magic number
    /// that's too strict for one collection and too loose for another.
    /// Deterministic (strided sample), O(sample × n) — run off-main, memoize.
    public struct NNStats: Sendable {
        public let mean: Double
        public let std: Double
        /// The similarity floor at `sigmas` standard deviations under the mean.
        public func floor(sigmas: Double) -> Double { mean - sigmas * std }
    }

    public func nnSimilarityStats(sampleCount: Int = 200) -> NNStats? {
        guard count >= 10 else { return nil }
        let samples = min(sampleCount, count)
        let stride = max(1, count / samples)
        var sum = 0.0, sumSq = 0.0
        var n = 0
        var row = 0
        // Reuse one scores buffer across all samples, and point the query straight
        // into the matrix row — no per-sample buffer allocation or row copy.
        var scores = [Float](repeating: 0, count: count)
        matrix.withUnsafeBufferPointer { mp in
            scores.withUnsafeMutableBufferPointer { sp in
                while row < count, n < samples {
                    vDSP_mmul(mp.baseAddress!, 1, mp.baseAddress! + row * dim, 1, sp.baseAddress!, 1,
                              vDSP_Length(count), 1, vDSP_Length(dim))
                    sp[row] = -1   // exclude self
                    var best: Float = 0
                    vDSP_maxv(sp.baseAddress!, 1, &best, vDSP_Length(count))
                    sum += Double(best); sumSq += Double(best) * Double(best); n += 1
                    row += stride
                }
            }
        }
        guard n > 1 else { return nil }
        let mean = sum / Double(n)
        let variance = max(0, sumSq / Double(n) - mean * mean)
        return NNStats(mean: mean, std: variance.squareRoot())
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = norm.squareRoot()
        guard norm > 1e-9 else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var inv = 1 / norm
        vDSP_vsmul(v, 1, &inv, &out, 1, vDSP_Length(v.count))
        return out
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
