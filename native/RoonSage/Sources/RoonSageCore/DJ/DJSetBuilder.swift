import AudioAnalysis
import Foundation

/// Builds a beatmatched, Camelot-compatible DJ set following a BPM/energy curve.
/// Ports backend/audio_features/dj_generator.py: greedy per-position selection
/// scored on BPM proximity, energy, harmonic compatibility and artist spread.
public struct DJSetBuilder {

    public enum Curve: String, CaseIterable, Sendable {
        case flat, rampUp = "ramp_up", rampDown = "ramp_down", peak
        public var label: String {
            switch self {
            case .flat: "Steady"; case .rampUp: "Build up"; case .rampDown: "Wind down"; case .peak: "Peak"
            }
        }
        /// Short Dutch subtitle describing the arc — used in the builder UI.
        public var blurb: String {
            switch self {
            case .flat:     "Gelijkmatig tempo"
            case .rampUp:   "Bouw langzaam op"
            case .rampDown: "Rustig uitfaden"
            case .peak:     "Piek in het midden"
            }
        }
    }

    /// The planned per-position BPM targets for a set — exposed so the UI can
    /// preview the tempo shape *before* building. Same math the builder uses.
    public static func plannedBPM(start: Double, end: Double, count: Int, curve: Curve) -> [Double] {
        bpmTargets(start: start, end: end, n: max(1, count), curve: curve)
    }

    public static func build(
        candidates: [DatabaseManager.DJCandidate],
        count: Int, startBPM: Double, endBPM: Double, curve: Curve
    ) -> [DatabaseManager.DJCandidate] {
        guard !candidates.isEmpty else { return [] }
        let n = min(count, candidates.count)
        let bpmTargets = bpmTargets(start: startBPM, end: endBPM, n: n, curve: curve)
        let energyTargets = curveValues(curve, n).map { 0.35 + $0 * 0.5 }

        var pool = candidates
        var result: [DatabaseManager.DJCandidate] = []
        var recentArtists: [String] = []
        var prevCamelot: String?
        var prevLoudness: Double?

        for i in 0..<n {
            var bestIdx = 0
            var bestScore = Double.infinity
            for (idx, c) in pool.enumerated() {
                let s = score(c, targetBPM: bpmTargets[i], targetEnergy: energyTargets[i],
                              prevCamelot: prevCamelot, prevLoudness: prevLoudness, recentArtists: recentArtists)
                if s < bestScore { bestScore = s; bestIdx = idx }
            }
            let chosen = pool.remove(at: bestIdx)
            result.append(chosen)
            prevCamelot = chosen.camelot
            prevLoudness = chosen.loudness
            recentArtists.append(chosen.artist ?? "")
            if recentArtists.count > 8 { recentArtists.removeFirst() }
            if pool.isEmpty { break }
        }
        return result
    }

    // MARK: - Scoring (lower is better)

    private static func effectiveBPM(_ bpm: Double, target: Double) -> Double {
        [bpm, bpm * 2, bpm / 2].min { abs($0 - target) < abs($1 - target) } ?? bpm
    }

    private static func score(
        _ c: DatabaseManager.DJCandidate, targetBPM: Double, targetEnergy: Double,
        prevCamelot: String?, prevLoudness: Double?, recentArtists: [String]
    ) -> Double {
        let bpm = effectiveBPM(c.bpm, target: targetBPM)
        let bpmPen = abs(bpm - targetBPM) / 4.0
        let energyPen = abs(c.energy - targetEnergy)

        let artist = c.artist ?? ""
        var artistPen = 0.0
        if recentArtists.suffix(3).contains(artist) { artistPen = 0.6 }
        else if recentArtists.contains(artist) { artistPen = 0.2 }

        var harmonic = 0.0
        if let prev = prevCamelot, !c.camelot.isEmpty {
            if c.camelot == prev { harmonic = -0.05 }
            else if Camelot.compatible(prev).contains(c.camelot) { harmonic = -0.25 }
        }

        // Loudness continuity (F3): a SMALL nudge away from big perceived-level jumps
        // between consecutive tracks, so a quiet ballad doesn't slam into a loud
        // banger. A separate concern from the energy arc (which tracks a target
        // curve); this only compares to the previous pick. Fully skipped — behaviour
        // identical to before — when either track lacks a loudness value (~6 LU is a
        // clearly audible jump; capped so an outlier can't dominate the score).
        var loudnessPen = 0.0
        if let prev = prevLoudness, let cur = c.loudness {
            loudnessPen = min(1.5, abs(cur - prev) / 6.0)
        }

        return 1.2 * bpmPen + 0.8 * energyPen + artistPen + harmonic + 0.25 * loudnessPen
    }

    // MARK: - Curves

    private static func curveValues(_ curve: Curve, _ n: Int) -> [Double] {
        guard n > 1 else { return [0.5] }
        return (0..<n).map { i in
            let t = Double(i) / Double(n - 1)
            switch curve {
            case .flat:     return 0.5
            case .rampUp:   return t
            case .rampDown: return 1 - t
            case .peak:     return 1 - abs(2 * t - 1)
            }
        }
    }

    private static func bpmTargets(start: Double, end: Double, n: Int, curve: Curve) -> [Double] {
        guard n > 1 else { return [start] }
        let raw = curveValues(curve, n)
        let lo = min(start, end), hi = max(start, end)
        guard let vMin = raw.min(), let vMax = raw.max(), vMax > vMin else {
            return Array(repeating: (start + end) / 2, count: n)
        }
        return raw.map { lo + ($0 - vMin) / (vMax - vMin) * (hi - lo) }
    }
}
