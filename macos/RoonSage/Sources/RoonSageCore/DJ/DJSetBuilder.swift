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

        for i in 0..<n {
            var bestIdx = 0
            var bestScore = Double.infinity
            for (idx, c) in pool.enumerated() {
                let s = score(c, targetBPM: bpmTargets[i], targetEnergy: energyTargets[i],
                              prevCamelot: prevCamelot, recentArtists: recentArtists)
                if s < bestScore { bestScore = s; bestIdx = idx }
            }
            let chosen = pool.remove(at: bestIdx)
            result.append(chosen)
            prevCamelot = chosen.camelot
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
        prevCamelot: String?, recentArtists: [String]
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
        return 1.2 * bpmPen + 0.8 * energyPen + artistPen + harmonic
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
