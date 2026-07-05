import Foundation

/// Grounds AI playlist titles in *measured* audio — the fix for "RoonSage ·
/// Acoustic" on music that isn't acoustic. Three tools, all pure:
///
///  1. **Calibration** — library-relative percentiles per CLAP attribute axis,
///     so "akoestisch" means "acoustic *for this library*", not an absolute
///     zero-shot score that may sit mis-scaled for a genre-skewed collection.
///  2. **Selection stats + claim validation** — a lexicon mapping style words a
///     title might claim ("akoestisch", "dansbaar", "rustig", …) to the measured
///     attribute/energy they must agree with. A generated title that contradicts
///     the measurements is rejected (the LLM gets one corrective retry).
///  3. **Profile signature** — a coarse banded fingerprint of a selection's
///     sonic character. Stable across the daily track rotation (bands, not
///     track lists), but it *shifts* when the station's actual sound drifts —
///     the trigger to regenerate a cached title so the Qobuz name keeps
///     describing what's inside.
public enum TitleGrounding {

    // MARK: - Library calibration (percentiles per attribute axis)

    /// Sorted per-axis attribute values over the analyzed library. Percentile
    /// lookups make attribute bands library-relative instead of absolute.
    public struct Calibration: Sendable {
        let sorted: [String: [Float]]

        public static func compute(library: [DatabaseManager.SonicTrack]) -> Calibration {
            var byAxis: [String: [Float]] = [:]
            for t in library {
                for (k, v) in t.attributes { byAxis[k, default: []].append(v) }
            }
            for k in byAxis.keys { byAxis[k]?.sort() }
            return Calibration(sorted: byAxis)
        }

        /// Fraction of the library scoring BELOW `value` on `axis` (0…1), or nil
        /// when the library has no data for that axis.
        public func percentile(of value: Float, axis: String) -> Double? {
            guard let vals = sorted[axis], !vals.isEmpty else { return nil }
            // Binary search for the insertion point.
            var lo = 0, hi = vals.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if vals[mid] < value { lo = mid + 1 } else { hi = mid }
            }
            return Double(lo) / Double(vals.count)
        }
    }

    // MARK: - Selection stats

    /// Measured character of one playlist selection: mean attribute per axis
    /// (only axes that actually have data) and mean energy.
    public struct SelectionStats: Sendable {
        public var attributeAvg: [String: Float]
        public var energyAvg: Double?

        public static func compute(_ tracks: [DatabaseManager.SonicTrack]) -> SelectionStats {
            var sum: [String: Float] = [:]
            var cnt: [String: Int] = [:]
            for t in tracks {
                for (k, v) in t.attributes { sum[k, default: 0] += v; cnt[k, default: 0] += 1 }
            }
            var avg: [String: Float] = [:]
            for (k, n) in cnt where n > 0 { avg[k] = sum[k]! / Float(n) }
            let energies = tracks.compactMap(\.energy)
            let e = energies.isEmpty ? nil : energies.reduce(0, +) / Double(energies.count)
            return SelectionStats(attributeAvg: avg, energyAvg: e)
        }
    }

    // MARK: - Attribute bands (calibrated, for the title prompt)

    /// The Dutch descriptor for one attribute axis when the selection clearly
    /// leans one way — judged BOTH absolutely and against the library
    /// distribution, so a noisy zero-shot axis can't claim a character the
    /// library doesn't support. nil = neutral (don't mention it).
    public static func band(
        axis: String, selectionAvg: Float, calibration: Calibration?
    ) -> String? {
        let words: (high: String, low: String)
        switch axis {
        case "valence":          words = ("vrolijk", "melancholisch")
        case "danceability":     words = ("dansbaar", "ingetogen ritme")
        case "acousticness":     words = ("akoestisch", "elektronisch")
        case "instrumentalness": words = ("instrumentaal", "met zang")
        default: return nil
        }
        let pct = calibration?.percentile(of: selectionAvg, axis: axis)
        // High: clearly above the neutral midpoint AND in the library's upper
        // reaches (when we can calibrate). Low: mirrored.
        if selectionAvg >= 0.55, pct.map({ $0 >= 0.60 }) ?? true { return words.high }
        if selectionAvg <= 0.45, pct.map({ $0 <= 0.40 }) ?? true { return words.low }
        return nil
    }

    // MARK: - Claim validation

    /// One style claim a title can make, and the measurement that must back it.
    struct Claim {
        let words: [String]         // lowercased title substrings that assert it
        let axis: String?           // attribute axis, nil = energy
        let wantsHigh: Bool         // claims a HIGH value on the axis
        let contradiction: Float    // measured value beyond this (on the wrong side) = violation
        let label: String           // human-readable, for the corrective retry prompt
    }

    static let claims: [Claim] = [
        Claim(words: ["akoestisch", "acoustic", "unplugged"],
              axis: "acousticness", wantsHigh: true, contradiction: 0.45,
              label: "akoestisch (gemeten: overwegend elektronisch)"),
        Claim(words: ["elektronisch", "electronic", "electro", "synth"],
              axis: "acousticness", wantsHigh: false, contradiction: 0.60,
              label: "elektronisch (gemeten: overwegend akoestisch)"),
        Claim(words: ["instrumentaal", "instrumental"],
              axis: "instrumentalness", wantsHigh: true, contradiction: 0.45,
              label: "instrumentaal (gemeten: overwegend met zang)"),
        Claim(words: ["dansbaar", "dansbare", "danceable", "dance-", " dance", "club"],
              axis: "danceability", wantsHigh: true, contradiction: 0.45,
              label: "dansbaar (gemeten: weinig dansbaar)"),
        Claim(words: ["vrolijk", "vrolijke", "zonnig", "zonnige", "feelgood", "uplifting", "opgewekt", "opgewekte"],
              axis: "valence", wantsHigh: true, contradiction: 0.42,
              label: "vrolijk (gemeten: eerder melancholisch)"),
        Claim(words: ["melancholisch", "melancholische", "somber", "sombere", "droevig", "droevige", "weemoedig", "weemoedige"],
              axis: "valence", wantsHigh: false, contradiction: 0.62,
              label: "melancholisch (gemeten: eerder vrolijk)"),
        Claim(words: ["rustig", "rustige", "kalm", "kalme", "chill", "ontspannen", "zacht", "zachte", "ingetogen"],
              axis: nil, wantsHigh: false, contradiction: 0.65,
              label: "rustig (gemeten: hoge energie)"),
        Claim(words: ["energiek", "energieke", "stevig", "stevige", "krachtig", "krachtige", "opzwepend", "opzwepende", "intens", "intense", "uptempo"],
              axis: nil, wantsHigh: true, contradiction: 0.42,
              label: "energiek (gemeten: lage energie)"),
    ]

    /// Style words in `title` that the measured stats contradict. Empty = the
    /// title is grounded (or makes no verifiable claims — that's fine too).
    /// Axes without measured data are never violations: absence of evidence
    /// isn't contradiction, and blocking on it would starve un-attributed
    /// libraries of titles entirely.
    public static func violations(title: String, stats: SelectionStats) -> [String] {
        let t = title.lowercased()
        var out: [String] = []
        for c in claims {
            guard c.words.contains(where: { t.contains($0) }) else { continue }
            let measured: Float?
            if let axis = c.axis { measured = stats.attributeAvg[axis] }
            else { measured = stats.energyAvg.map(Float.init) }
            guard let m = measured else { continue }
            let violated = c.wantsHigh ? (m < c.contradiction) : (m > c.contradiction)
            if violated { out.append(c.label) }
        }
        return out
    }

    // MARK: - Profile signature (title-regeneration trigger)

    /// A coarse, banded fingerprint of a selection's sonic character. Deliberately
    /// insensitive to the daily track rotation (bands + top-N sets, not track
    /// lists); it only changes when the station's actual *sound* drifts — which is
    /// exactly when a cached title should be regenerated to match.
    public static func profileSignature(_ tracks: [DatabaseManager.SonicTrack]) -> String {
        guard !tracks.isEmpty else { return "" }
        var parts: [String] = []

        // Energy band (3 levels).
        let energies = tracks.compactMap(\.energy)
        if !energies.isEmpty {
            let avg = energies.reduce(0, +) / Double(energies.count)
            parts.append("e:\(avg < 0.4 ? "laag" : (avg < 0.7 ? "midden" : "hoog"))")
        }

        // Top-2 moods (order-independent).
        var moodSum: [String: Float] = [:]
        for t in tracks { for (m, v) in t.moods { moodSum[m, default: 0] += v } }
        let topMoods = moodSum.sorted { $0.value > $1.value }.prefix(2).map(\.key).sorted()
        if !topMoods.isEmpty { parts.append("m:\(topMoods.joined(separator: ","))") }

        // Top-3 tags (order-independent).
        var tagCount: [String: Int] = [:]
        for t in tracks { for tag in t.tags { tagCount[tag.lowercased(), default: 0] += 1 } }
        let topTags = tagCount.sorted { $0.value > $1.value }.prefix(3).map(\.key).sorted()
        if !topTags.isEmpty { parts.append("t:\(topTags.joined(separator: ","))") }

        // Attribute bands (h/l/n per axis, fixed axis order).
        let stats = SelectionStats.compute(tracks)
        var bands: [String] = []
        for axis in ["valence", "danceability", "acousticness", "instrumentalness"] {
            guard let v = stats.attributeAvg[axis] else { bands.append("-"); continue }
            bands.append(v >= 0.55 ? "h" : (v <= 0.45 ? "l" : "n"))
        }
        parts.append("a:\(bands.joined())")

        // Tempo, rounded to 15 BPM so daily wobble doesn't flip the signature.
        let bpms = tracks.compactMap(\.bpm).filter { $0 > 0 }
        if !bpms.isEmpty {
            let avg = bpms.reduce(0, +) / Double(bpms.count)
            parts.append("b:\(Int((avg / 15).rounded()) * 15)")
        }
        return parts.joined(separator: "|")
    }
}
