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
        guard let (na, la) = parseCamelot(a), let (nb, lb) = parseCamelot(b) else { return 0.5 }
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

    static func parseCamelot(_ code: String) -> (Int, Character)? {
        guard let letter = code.last, letter == "A" || letter == "B",
              let num = Int(code.dropLast()), (1...12).contains(num) else { return nil }
        return (num, letter)
    }

    // MARK: - Pre-parsed feature (avoids repeated Set<String> alloc + Camelot parsing)

    public struct Prepared: Sendable {
        let camelot: String
        let bpm: Double
        let energy: Double
        let camelotNum: Int     // -1 if unparseable
        let camelotLetter: Character
        let tagSet: Set<String>

        public init(_ f: Feature) {
            self.camelot = f.camelot
            self.bpm = f.bpm ?? 0
            self.energy = f.energy ?? 0.5
            if let (num, letter) = SonicSimilarity.parseCamelot(f.camelot) {
                self.camelotNum = num
                self.camelotLetter = letter
            } else {
                self.camelotNum = -1
                self.camelotLetter = "A"
            }
            self.tagSet = Set(f.tags)
        }
    }

    /// Fast distance between two pre-parsed features. No allocations in the hot path.
    public static func distance(_ a: Prepared, _ b: Prepared, weights w: Weights = .default) -> Double {
        // BPM
        let dBpm: Double
        if a.bpm > 0, b.bpm > 0 {
            let d1 = abs(a.bpm - b.bpm)
            let d2 = abs(a.bpm - b.bpm * 2)
            let d3 = abs(a.bpm - b.bpm / 2)
            dBpm = min(1, min(d1, min(d2, d3)) / 40.0)
        } else { dBpm = 0.5 }

        // Energy
        let dEnergy: Double
        if a.energy != 0.5, b.energy != 0.5 {
            dEnergy = min(1, abs(a.energy - b.energy))
        } else { dEnergy = 0.5 }

        // Key
        let dKey: Double
        if a.camelotNum == -1 || b.camelotNum == -1 {
            dKey = 0.5
        } else if a.camelot == b.camelot {
            dKey = 0
        } else if Camelot.compatible(a.camelot).contains(b.camelot) {
            dKey = 0.15
        } else {
            let diff = abs(a.camelotNum - b.camelotNum)
            let hours = Double(min(diff, 12 - diff))
            let letterPenalty = a.camelotLetter == b.camelotLetter ? 0.0 : 0.1
            dKey = min(1, hours / 6.0 * 0.9 + letterPenalty)
        }

        // Tags (Jaccard)
        let dTags: Double
        if a.tagSet.isEmpty || b.tagSet.isEmpty {
            dTags = 0.5
        } else {
            let inter = a.tagSet.intersection(b.tagSet).count
            let union = a.tagSet.union(b.tagSet).count
            dTags = union > 0 ? 1 - Double(inter) / Double(union) : 0.5
        }

        let total = w.bpm + w.energy + w.key + w.tags
        guard total > 0 else { return 0.5 }
        return (w.bpm * dBpm + w.energy * dEnergy + w.key * dKey + w.tags * dTags) / total
    }

    public static func similarity(_ a: Prepared, _ b: Prepared, weights: Weights = .default) -> Double {
        1 - distance(a, b, weights: weights)
    }
}
