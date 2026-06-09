import AudioAnalysis
import Foundation

/// Pure, ML-free sonic similarity over the analyzer's per-track features
/// (tempo, harmonic key, energy, LLM tags). Shared by Sonic Radio, Sonic
/// Fingerprint and the Music Map so they rank tracks identically.
public enum SonicSimilarity {

    /// A lightweight feature point. Works for a real track or a synthetic
    /// profile (e.g. a listening-history centroid).
    public struct Feature: Sendable {
        public var bpm: Double?
        public var camelot: String
        public var energy: Double?
        public var tags: [String]
        public init(bpm: Double?, camelot: String, energy: Double?, tags: [String]) {
            self.bpm = bpm; self.camelot = camelot; self.energy = energy; self.tags = tags
        }
    }

    public struct Weights: Sendable {
        public var bpm: Double
        public var energy: Double
        public var key: Double
        public var tags: Double
        public init(bpm: Double = 0.30, energy: Double = 0.20, key: Double = 0.20, tags: Double = 0.30) {
            self.bpm = bpm; self.energy = energy; self.key = key; self.tags = tags
        }
        public static let `default` = Weights()
    }

    /// Distance in [0, 1]; lower = more similar. Components that can't be
    /// computed (missing data on either side) contribute a neutral 0.5 so a
    /// track is never unfairly rewarded or punished for missing metadata.
    public static func distance(_ a: Feature, _ b: Feature, weights w: Weights = .default) -> Double {
        let dBpm = tempoDistance(a.bpm, b.bpm)
        let dEnergy = energyDistance(a.energy, b.energy)
        let dKey = keyDistance(a.camelot, b.camelot)
        let dTags = tagDistance(a.tags, b.tags)
        let total = w.bpm + w.energy + w.key + w.tags
        guard total > 0 else { return 0.5 }
        return (w.bpm * dBpm + w.energy * dEnergy + w.key * dKey + w.tags * dTags) / total
    }

    /// Convenience: similarity in [0, 1] where 1 = identical.
    public static func similarity(_ a: Feature, _ b: Feature, weights: Weights = .default) -> Double {
        1 - distance(a, b, weights: weights)
    }

    // MARK: - Components

    /// Tempo distance with half/double-time tolerance, scaled so a ~40 BPM gap
    /// is "very different".
    static func tempoDistance(_ a: Double?, _ b: Double?) -> Double {
        guard let a, let b, a > 0, b > 0 else { return 0.5 }
        let candidates = [b, b * 2, b / 2]
        let best = candidates.map { abs(a - $0) }.min() ?? abs(a - b)
        return min(1, best / 40.0)
    }

    static func energyDistance(_ a: Double?, _ b: Double?) -> Double {
        guard let a, let b else { return 0.5 }
        return min(1, abs(a - b))
    }

    /// Camelot-wheel distance: 0 same code, 0.15 harmonically compatible,
    /// otherwise scaled by hours apart on the wheel (+ small penalty for a
    /// different major/minor letter).
    static func keyDistance(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0.5 }
        if a == b { return 0 }
        if Camelot.compatible(a).contains(b) { return 0.15 }
        guard let (na, la) = parse(a), let (nb, lb) = parse(b) else { return 0.5 }
        let hours = Double(min(abs(na - nb), 12 - abs(na - nb)))   // 0…6
        let letterPenalty = la == lb ? 0.0 : 0.1
        return min(1, hours / 6.0 * 0.9 + letterPenalty)
    }

    /// 1 − Jaccard overlap of tag sets. Neutral 0.5 if either side has no tags.
    static func tagDistance(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0.5 }
        let sa = Set(a), sb = Set(b)
        let inter = sa.intersection(sb).count
        let union = sa.union(sb).count
        guard union > 0 else { return 0.5 }
        return 1 - Double(inter) / Double(union)
    }

    private static func parse(_ code: String) -> (Int, Character)? {
        guard let letter = code.last, letter == "A" || letter == "B",
              let num = Int(code.dropLast()), (1...12).contains(num) else { return nil }
        return (num, letter)
    }
}
