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
        weights: SonicSimilarity.Weights = .default
    ) -> [Step] {
        let fromPrep = SonicSimilarity.Prepared(SonicSimilarity.Feature(
            bpm: from.bpm, camelot: from.camelot, energy: from.energy, tags: from.tags))
        let toPrep = SonicSimilarity.Prepared(SonicSimilarity.Feature(
            bpm: to.bpm, camelot: to.camelot, energy: to.energy, tags: to.tags))

        var used = Set<String>([from.id, to.id])
        var path: [Step] = [Step(track: from, similarity: 1)]
        var currentPrep = fromPrep
        let bridgeSteps = max(0, maxSteps - 2)

        // Precompute prepared features for the whole library once.
        let candidates: [(track: DatabaseManager.SonicTrack, prep: SonicSimilarity.Prepared)] = library
            .filter { !used.contains($0.id) }
            .map { ($0, SonicSimilarity.Prepared(SonicSimilarity.Feature(
                bpm: $0.bpm, camelot: $0.camelot, energy: $0.energy, tags: $0.tags))) }

        var remaining = candidates

        for step in 0..<bridgeSteps {
            guard !remaining.isEmpty else { break }
            let progress = bridgeSteps > 1 ? Double(step) / Double(bridgeSteps - 1) : 0.5
            let alpha = 0.3 + 0.4 * min(1, progress * 2)   // 0.3…0.7

            var bestScore = Double.infinity
            var bestIdx = 0
            for (i, c) in remaining.enumerated() {
                let dCurrent = SonicSimilarity.distance(currentPrep, c.prep, weights: weights)
                let dTarget  = SonicSimilarity.distance(c.prep, toPrep,    weights: weights)
                let score = alpha * dCurrent + (1 - alpha) * dTarget
                if score < bestScore { bestScore = score; bestIdx = i }
            }

            let chosen = remaining[bestIdx]
            let sim = SonicSimilarity.similarity(currentPrep, chosen.prep, weights: weights)
            path.append(Step(track: chosen.track, similarity: sim))
            currentPrep = chosen.prep
            used.insert(chosen.track.id)
            remaining.remove(at: bestIdx)
        }

        let toSim = SonicSimilarity.similarity(currentPrep, toPrep, weights: weights)
        path.append(Step(track: to, similarity: toSim))
        return path
    }
}
