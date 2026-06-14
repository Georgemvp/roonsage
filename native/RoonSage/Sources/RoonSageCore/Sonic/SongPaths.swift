import Foundation

/// Greedy nearest-neighbour bridge between two tracks.
/// At each hop, picks the unvisited library track that minimises:
///   α × distance(current, candidate) + (1-α) × distance(candidate, target)
/// where α grows from 0.3 → 0.7 as progress approaches midpoint (first half
/// biased toward target, second half toward current vicinity).
public enum SongPaths {

    public struct Step: Sendable, Identifiable {
        public var id: String { track.id }
        public var track: DatabaseManager.SonicTrack
        public var similarity: Double   // to the previous step
    }

    /// Find a path from `from` to `to` through `library`.
    /// Returns `[from] + bridge + [to]` (inclusive endpoints), max `maxSteps` total.
    public static func find(
        from: DatabaseManager.SonicTrack,
        to: DatabaseManager.SonicTrack,
        library: [DatabaseManager.SonicTrack],
        maxSteps: Int = 12,
        weights: SonicSimilarity.Weights = .default,
        index: VectorIndex? = nil
    ) -> [Step] {
        let fromPrep = SonicSimilarity.Prepared(SonicSimilarity.Feature(
            bpm: from.bpm, camelot: from.camelot, energy: from.energy, tags: from.tags))
        let toPrep = SonicSimilarity.Prepared(SonicSimilarity.Feature(
            bpm: to.bpm, camelot: to.camelot, energy: to.energy, tags: to.tags))

        // Embedding mode when both endpoints carry a vector: cosine drives the
        // walk, with Camelot/BPM/tags distance as a light secondary tie-break.
        let useEmb = index?.embedding(forId: from.id) != nil && index?.embedding(forId: to.id) != nil
        let toVec = useEmb ? index?.embedding(forId: to.id) : nil
        let secondaryWeight = 0.15

        var used = Set<String>([from.id, to.id])
        var path: [Step] = [Step(track: from, similarity: 1)]
        var currentPrep = fromPrep
        var currentVec = useEmb ? index?.embedding(forId: from.id) : nil
        let bridgeSteps = max(0, maxSteps - 2)

        // Precompute prepared features (+ embedding) for the library once. In
        // embedding mode, only vector-bearing candidates are eligible.
        struct Cand { let track: DatabaseManager.SonicTrack; let prep: SonicSimilarity.Prepared; let vec: [Float]? }
        var remaining: [Cand] = library
            .filter { !used.contains($0.id) }
            .map { Cand(track: $0,
                        prep: SonicSimilarity.Prepared(SonicSimilarity.Feature(
                            bpm: $0.bpm, camelot: $0.camelot, energy: $0.energy, tags: $0.tags)),
                        vec: useEmb ? index?.embedding(forId: $0.id) : nil) }
        if useEmb { remaining = remaining.filter { $0.vec != nil } }

        func cosDist(_ a: [Float]?, _ b: [Float]?) -> Double {
            guard let a, let b else { return 1 }
            var dot: Float = 0
            for i in 0..<min(a.count, b.count) { dot += a[i] * b[i] }
            return Double(1 - max(-1, min(1, dot)))
        }

        for step in 0..<bridgeSteps {
            guard !remaining.isEmpty else { break }
            let progress = bridgeSteps > 1 ? Double(step) / Double(bridgeSteps - 1) : 0.5
            let alpha = 0.3 + 0.4 * min(1, progress * 2)   // 0.3…0.7

            var bestScore = Double.infinity
            var bestIdx = 0
            for (i, c) in remaining.enumerated() {
                let dCurrent: Double
                let dTarget: Double
                if useEmb {
                    let secondary = secondaryWeight * SonicSimilarity.distance(currentPrep, c.prep, weights: weights)
                    dCurrent = cosDist(currentVec, c.vec) + secondary
                    dTarget = cosDist(c.vec, toVec)
                } else {
                    dCurrent = SonicSimilarity.distance(currentPrep, c.prep, weights: weights)
                    dTarget = SonicSimilarity.distance(c.prep, toPrep, weights: weights)
                }
                let score = alpha * dCurrent + (1 - alpha) * dTarget
                if score < bestScore { bestScore = score; bestIdx = i }
            }

            let chosen = remaining[bestIdx]
            let sim = useEmb ? max(0, 1 - cosDist(currentVec, chosen.vec))
                             : SonicSimilarity.similarity(currentPrep, chosen.prep, weights: weights)
            path.append(Step(track: chosen.track, similarity: sim))
            currentPrep = chosen.prep
            currentVec = chosen.vec
            used.insert(chosen.track.id)
            remaining.remove(at: bestIdx)
        }

        let toSim = useEmb ? max(0, 1 - cosDist(currentVec, toVec))
                           : SonicSimilarity.similarity(currentPrep, toPrep, weights: weights)
        path.append(Step(track: to, similarity: toSim))
        return path
    }
}
