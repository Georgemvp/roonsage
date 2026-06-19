import AudioAnalysis
import Foundation

/// Orders a set of sonically-related tracks into a *flowing* sequence — the
/// thing that makes a radio feel designed rather than shuffled. A great station
/// (or DJ set) doesn't jump between sonic worlds track-to-track; it glides.
///
/// We greedily build a path that, at each hop, picks the unplayed track with the
/// smoothest transition from the current one, scored on:
///   • embedding proximity (CLAP cosine) — the dominant "does this belong next" signal,
///   • tempo continuity (BPM, half/double-time aware),
///   • harmonic compatibility (Camelot wheel — reuses the DJ logic),
///   • a gentle energy arc so the station breathes instead of flatlining.
///
/// Pure + deterministic: identical input + start always yields the same order,
/// so it composes with the daily-salt variety upstream without reshuffling.
public enum RadioSequencer {

    /// Shape of the energy curve across the sequence.
    public enum Arc: Sendable {
        case smooth      // minimise track-to-track energy jumps (endless radio)
        case gentleRise  // start calm, drift up (a "set" with a little lift)
        case peak        // rise to a middle peak, then ease off

        func target(_ progress: Double, base: Double) -> Double {
            switch self {
            case .smooth:     return base
            case .gentleRise: return min(1, base * 0.85 + 0.30 * progress)
            case .peak:       return min(1, base * 0.85 + 0.30 * (1 - abs(2 * progress - 1)))
            }
        }
    }

    public struct Weights: Sendable {
        public var embedding: Double
        public var bpm: Double
        public var key: Double
        public var energy: Double
        public init(embedding: Double = 1.0, bpm: Double = 0.5, key: Double = 0.4, energy: Double = 0.35) {
            self.embedding = embedding; self.bpm = bpm; self.key = key; self.energy = energy
        }
        public static let `default` = Weights()
    }

    /// Reorder `tracks` into a smooth journey. When `preferredStartIds` is given,
    /// the walk opens on the highest-energy track among them (so e.g. an artist
    /// station opens on the seed artist); otherwise it opens on the input's first
    /// track. Tracks are never dropped — only reordered.
    public static func order(
        _ tracks: [DatabaseManager.SonicTrack],
        preferredStartIds: Set<String> = [],
        arc: Arc = .smooth,
        weights: Weights = .default
    ) -> [DatabaseManager.SonicTrack] {
        guard tracks.count > 2 else { return tracks }

        // Pre-parse the rule-based features once (used when an embedding is absent).
        struct Node {
            let track: DatabaseManager.SonicTrack
            let prep: SonicSimilarity.Prepared
            let emb: [Float]?
            let energy: Double
            let bpmConfidence: Double   // 1 when unknown — trust it fully
        }
        let nodes = tracks.map { t -> Node in
            Node(track: t,
                 prep: SonicSimilarity.Prepared(SonicSimilarity.Feature(
                    bpm: t.bpm, camelot: t.camelot, energy: t.energy, tags: t.tags)),
                 emb: (t.embedding?.isEmpty == false) ? VectorIndex.normalized(t.embedding!) : nil,
                 energy: t.energy ?? 0.5,
                 bpmConfidence: t.bpmConfidence.map { max(0, min(1, $0)) } ?? 1)
        }

        let baseEnergy = nodes.map(\.energy).reduce(0, +) / Double(nodes.count)

        // Choose the opening track.
        var startIdx = 0
        if !preferredStartIds.isEmpty {
            let candidates = nodes.indices.filter { preferredStartIds.contains(nodes[$0].track.id) }
            if let best = candidates.max(by: { nodes[$0].energy < nodes[$1].energy }) { startIdx = best }
        }

        var remaining = Set(nodes.indices)
        var orderIdx: [Int] = [startIdx]
        remaining.remove(startIdx)
        var current = nodes[startIdx]
        let total = Double(nodes.count - 1)

        func cosDist(_ a: [Float]?, _ b: [Float]?) -> Double {
            guard let a, let b else { return 0.5 }   // neutral when either lacks a vector
            var dot: Float = 0
            let n = min(a.count, b.count)
            var i = 0
            while i < n { dot += a[i] * b[i]; i += 1 }
            return Double(1 - max(-1, min(1, dot)))
        }

        while !remaining.isEmpty {
            let progress = Double(orderIdx.count) / max(1, total)
            let targetEnergy = arc.target(progress, base: baseEnergy)
            var bestIdx = -1
            var bestCost = Double.infinity
            // Iterate a SORTED snapshot, not the Set directly: Swift Set iteration
            // order is randomized per process, so on an exact-cost tie (e.g. tracks
            // sharing bpm/key/energy with no embedding) the winner would differ
            // across launches — breaking the determinism contract and the
            // daily-stable Qobuz playlists. Lowest index wins ties, deterministically.
            for i in remaining.sorted() {
                let cand = nodes[i]
                let dEmb = cosDist(current.emb, cand.emb)
                let dBpm = SonicSimilarity.tempoDistance(current.track.bpm, cand.track.bpm)
                let dKey = SonicSimilarity.keyDistance(current.track.camelot, cand.track.camelot)
                let dEnergy = abs(cand.energy - targetEnergy)
                // A low-confidence BPM is unreliable, so let it steer the flow less
                // (the embedding/key terms carry it instead).
                let bpmTrust = min(current.bpmConfidence, cand.bpmConfidence)
                let cost = weights.embedding * dEmb + weights.bpm * bpmTrust * dBpm
                         + weights.key * dKey + weights.energy * dEnergy
                if cost < bestCost { bestCost = cost; bestIdx = i }
            }
            guard bestIdx >= 0 else { break }
            orderIdx.append(bestIdx)
            remaining.remove(bestIdx)
            current = nodes[bestIdx]
        }
        return orderIdx.map { nodes[$0].track }
    }
}
