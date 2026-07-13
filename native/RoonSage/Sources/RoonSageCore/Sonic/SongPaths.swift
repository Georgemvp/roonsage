import Foundation

/// Bridge between two tracks.
///
/// Embedding mode (gap B, AudioMuse-schema): interpoleer `bridgeSteps`
/// waypoint-vectoren op de lijn from→to (per waypoint gerenormaliseerd) en kies
/// per waypoint de dichtstbijzijnde ongebruikte kandidaat — een gelijkmatige
/// sonische gradiënt. De vroegere greedy walk kon in de eerste helft afdrijven
/// (α-gewogen doelafstand trok stappen te vroeg naar het doel).
///
/// Scalar-fallback (geen embeddings): de oorspronkelijke greedy hop die
///   α × distance(current, candidate) + (1-α) × distance(candidate, target)
/// minimaliseert, met α 0.3 → 0.7 over de brug.
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

        if useEmb, let fromVec = currentVec, let targetVec = toVec {
            // Waypoint-interpolatie: bridgeSteps=2 → t = 1/3, 2/3; =1 → t = 1/2;
            // =0 → geen waypoints (alleen endpoints).
            for step in 0..<bridgeSteps {
                guard !remaining.isEmpty else { break }
                let t = Double(step + 1) / Double(bridgeSteps + 1)
                var way = [Float](repeating: 0, count: fromVec.count)
                for d in 0..<min(fromVec.count, targetVec.count) {
                    way[d] = Float(1 - t) * fromVec[d] + Float(t) * targetVec[d]
                }
                way = VectorIndex.normalized(way)

                var bestScore = Double.infinity
                var bestIdx = 0
                for (i, c) in remaining.enumerated() {
                    // Scalar-afstand blijft een lichte tie-break, zodat Camelot/
                    // BPM-botsingen tussen bijna-gelijke kandidaten beslissen.
                    let secondary = secondaryWeight * SonicSimilarity.distance(currentPrep, c.prep, weights: weights)
                    let score = cosDist(way, c.vec) + secondary
                    if score < bestScore { bestScore = score; bestIdx = i }
                }

                let chosen = remaining[bestIdx]
                path.append(Step(track: chosen.track, similarity: max(0, 1 - cosDist(currentVec, chosen.vec))))
                currentPrep = chosen.prep
                currentVec = chosen.vec
                used.insert(chosen.track.id)
                remaining.remove(at: bestIdx)
            }
        } else {
            for step in 0..<bridgeSteps {
                guard !remaining.isEmpty else { break }
                let progress = bridgeSteps > 1 ? Double(step) / Double(bridgeSteps - 1) : 0.5
                let alpha = 0.3 + 0.4 * min(1, progress * 2)   // 0.3…0.7

                var bestScore = Double.infinity
                var bestIdx = 0
                for (i, c) in remaining.enumerated() {
                    let dCurrent = SonicSimilarity.distance(currentPrep, c.prep, weights: weights)
                    let dTarget = SonicSimilarity.distance(c.prep, toPrep, weights: weights)
                    let score = alpha * dCurrent + (1 - alpha) * dTarget
                    if score < bestScore { bestScore = score; bestIdx = i }
                }

                let chosen = remaining[bestIdx]
                path.append(Step(track: chosen.track,
                                 similarity: SonicSimilarity.similarity(currentPrep, chosen.prep, weights: weights)))
                currentPrep = chosen.prep
                used.insert(chosen.track.id)
                remaining.remove(at: bestIdx)
            }
        }

        let toSim = useEmb ? max(0, 1 - cosDist(currentVec, toVec))
                           : SonicSimilarity.similarity(currentPrep, toPrep, weights: weights)
        path.append(Step(track: to, similarity: toSim))
        return path
    }
}
