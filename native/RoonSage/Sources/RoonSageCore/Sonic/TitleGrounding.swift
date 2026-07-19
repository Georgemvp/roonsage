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

    /// The per-track energy signal: PERCEPTUAL arousal (CLAP) when present, else
    /// the waveform's linear RMS `energy`. Arousal is semantic intensity from the
    /// embedding and orders busy-but-quiet vs loud-but-sparse correctly, unlike
    /// RMS (which put acoustic folk above techno on this library). The `energy`
    /// fallback keeps pre-arousal libraries working.
    public static func energySignal(_ t: DatabaseManager.SonicTrack) -> Double? {
        t.energySignal
    }

    /// Synthetic calibration key for the energy signal (so it lives in the same
    /// percentile machinery as the real attribute axes).
    public static let energyAxis = "energy_signal"

    /// Sorted per-axis attribute values over the analyzed library. Percentile
    /// lookups make attribute bands library-relative instead of absolute — the
    /// fix for a compressed axis (e.g. RMS energy crushed into [0, 0.6]): "high"
    /// means high FOR THIS LIBRARY, not against an absolute scale that no track
    /// reaches.
    public struct Calibration: Sendable {
        let sorted: [String: [Float]]
        /// Per-mood z-score statistics over the same library, so profile/title
        /// code can judge moods against the library baseline (CLAP's text prior
        /// makes "danceable" outscore "sad" everywhere; raw averages are biased).
        public let moods: MoodCalibration?

        public static func compute(library: [DatabaseManager.SonicTrack]) -> Calibration {
            var byAxis: [String: [Float]] = [:]
            for t in library {
                for (k, v) in t.attributes { byAxis[k, default: []].append(v) }
                if let e = energySignal(t) { byAxis[energyAxis, default: []].append(Float(e)) }
            }
            for k in byAxis.keys { byAxis[k]?.sort() }
            return Calibration(sorted: byAxis,
                               moods: library.isEmpty ? nil : MoodCalibration(tracks: library))
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

        /// Library-relative energy percentile of one track (0…1), or nil when the
        /// track has no energy signal / the library has no calibration.
        public func energyPercentile(_ t: DatabaseManager.SonicTrack) -> Double? {
            guard let e = energySignal(t) else { return nil }
            return percentile(of: Float(e), axis: energyAxis)
        }
    }

    // MARK: - Selection stats

    /// Measured character of one playlist selection: mean attribute per axis
    /// (only axes that actually have data) and mean energy SIGNAL (arousal-or-RMS).
    public struct SelectionStats: Sendable {
        public var attributeAvg: [String: Float]
        public var energyAvg: Double?          // mean energy SIGNAL (arousal preferred)

        public static func compute(_ tracks: [DatabaseManager.SonicTrack]) -> SelectionStats {
            var sum: [String: Float] = [:]
            var cnt: [String: Int] = [:]
            for t in tracks {
                for (k, v) in t.attributes { sum[k, default: 0] += v; cnt[k, default: 0] += 1 }
            }
            var avg: [String: Float] = [:]
            for (k, n) in cnt where n > 0 { avg[k] = sum[k]! / Float(n) }
            let energies = tracks.compactMap(energySignal)
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
        guard let words = bandWords(axis: axis),
              let high = bandDirection(axis: axis, selectionAvg: selectionAvg,
                                       calibration: calibration) else { return nil }
        return high ? words.high : words.low
    }

    /// The Dutch high/low descriptor pair for an attribute axis, or nil for an
    /// axis we don't describe (energy included — it has its own percentile path).
    static func bandWords(axis: String) -> (high: String, low: String)? {
        switch axis {
        case "valence":          return ("vrolijk", "melancholisch")
        case "danceability":     return ("dansbaar", "ingetogen ritme")
        case "acousticness":     return ("akoestisch", "elektronisch")
        case "instrumentalness": return ("instrumentaal", "met zang")
        default: return nil
        }
    }

    /// Which way an axis clearly leans for this selection: true = high, false =
    /// low, nil = neutral (don't claim anything).
    ///
    /// This is the SINGLE rule for attribute character. `band` uses it to assert
    /// a descriptor and `violations` uses it to reject one, so a title can only
    /// ever claim what the system would have said itself. Splitting those two
    /// into separate constants is what opened the 0.45–0.55 grey zone where the
    /// LLM could call a synth-pop station "akoestisch" unchallenged.
    static func bandDirection(
        axis: String, selectionAvg: Float, calibration: Calibration?
    ) -> Bool? {
        guard bandWords(axis: axis) != nil else { return nil }
        let pct = calibration?.percentile(of: selectionAvg, axis: axis)
        // High: clearly above the neutral midpoint AND in the library's upper
        // reaches (when we can calibrate). Low: mirrored.
        if selectionAvg >= 0.55, pct.map({ $0 >= 0.60 }) ?? true { return true }
        if selectionAvg <= 0.45, pct.map({ $0 <= 0.40 }) ?? true { return false }
        return nil
    }

    // MARK: - Claim validation

    /// One style claim a title can make, and the measurement that must back it.
    struct Claim {
        let words: [String]         // lowercased title substrings that assert it
        let axis: String?           // attribute axis, nil = energy
        let wantsHigh: Bool         // claims a HIGH value on the axis
        /// ENERGY claims only (`axis == nil`), and only when uncalibrated: measured
        /// value beyond this on the wrong side = violation. Attribute claims ignore
        /// this and go through `bandDirection`, which owns their thresholds.
        let contradiction: Float
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
    ///
    /// ENERGY claims are judged **library-relative** when `calibration` is given:
    /// the selection's mean energy signal is turned into a percentile, so "rustig"
    /// = bottom third / "energiek" = top third OF THIS LIBRARY. This is essential
    /// because the RMS energy axis is compressed (max ~0.6) — an absolute
    /// threshold would reject every "energiek" title outright. Attribute axes
    /// (valence/acousticness/…) stay on their absolute 0…1 scale, which is sound.
    public static func violations(title: String, stats: SelectionStats,
                                  calibration: Calibration? = nil) -> [String] {
        let t = title.lowercased()
        // Energy percentile of the selection's mean signal, when we can calibrate.
        let energyPct: Double? = {
            guard let cal = calibration, let e = stats.energyAvg else { return nil }
            return cal.percentile(of: Float(e), axis: energyAxis)
        }()
        var out: [String] = []
        for c in claims {
            guard c.words.contains(where: { t.contains($0) }) else { continue }
            if c.axis == nil {
                // Energy claim. Prefer the library percentile; fall back to the
                // absolute signal only when uncalibrated.
                if let pct = energyPct {
                    let violated = c.wantsHigh ? (pct < 0.34) : (pct > 0.66)
                    if violated { out.append(c.label) }
                } else if let m = stats.energyAvg.map(Float.init) {
                    let violated = c.wantsHigh ? (m < c.contradiction) : (m > c.contradiction)
                    if violated { out.append(c.label) }
                }
                continue
            }
            // Attribute claim. A claim is allowed exactly when the selection
            // leans that way by `bandDirection` — the same rule that would have
            // asserted the descriptor. Neutral (nil) contradicts every claim:
            // if we wouldn't say it, the LLM doesn't get to either.
            guard let axis = c.axis, let m = stats.attributeAvg[axis] else { continue }
            let leansHigh = bandDirection(axis: axis, selectionAvg: m, calibration: calibration)
            if leansHigh != c.wantsHigh { out.append(c.label) }
        }
        return out
    }

    /// Style claims anywhere in a station's user-visible copy. The description is
    /// checked with the same lexicon as the title — it reaches the user (and the
    /// Qobuz playlist) too, and used to be the one place an ungrounded
    /// "akoestisch" could survive unchecked.
    public static func violations(title: String, description: String,
                                  stats: SelectionStats,
                                  calibration: Calibration? = nil) -> [String] {
        let both = violations(title: title, stats: stats, calibration: calibration)
            + violations(title: description, stats: stats, calibration: calibration)
        // Same claim in title AND description is still one thing to fix.
        var seen = Set<String>()
        return both.filter { seen.insert($0).inserted }
    }

    /// The exact words a corrective retry must avoid — every trigger spelling of
    /// each violated claim, not the human-readable label.
    ///
    /// The labels read "melancholisch (gemeten: eerder vrolijk)", so telling the
    /// model to write "ZONDER deze woorden" also forbids *vrolijk* — the very
    /// word the measurements support. Two stations (Mark Knopfler, Emmanuel
    /// Lagumbay) kept re-emitting the banned word through both attempts because
    /// of it. This returns just the forbidden spellings, deduped and sorted.
    public static func violationWords(title: String, description: String,
                                      stats: SelectionStats,
                                      calibration: Calibration? = nil) -> [String] {
        let bad = Set(violations(title: title, description: description,
                                 stats: stats, calibration: calibration))
        guard !bad.isEmpty else { return [] }
        var out: Set<String> = []
        for c in claims where bad.contains(c.label) {
            for w in c.words {
                let trimmed = w.trimmingCharacters(in: .whitespaces)
                // Skip fragment matchers ("dance-", " dance") — they aren't words
                // a human-readable ban list can meaningfully name.
                if trimmed.count > 2, !trimmed.hasSuffix("-") { out.insert(trimmed) }
            }
        }
        return out.sorted()
    }

    // MARK: - Profile signature (title-regeneration trigger)

    /// A coarse, banded fingerprint of a selection's sonic character. Deliberately
    /// insensitive to the daily track rotation (bands + top-N sets, not track
    /// lists); it only changes when the station's actual *sound* drifts — which is
    /// exactly when a cached title should be regenerated to match.
    public static func profileSignature(_ tracks: [DatabaseManager.SonicTrack]) -> String {
        guard !tracks.isEmpty else { return "" }
        var parts: [String] = []

        // Energy band (3 levels) on the energy SIGNAL. Coarse absolute buckets are
        // fine for a signature — it only needs to be stable across the daily
        // rotation and shift on real drift, not to be library-calibrated.
        let energies = tracks.compactMap(energySignal)
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

        // Top-2 REAL genres (MusicBrainz/Deezer) — the profile leads with these,
        // so a genre shift must shift the signature (and regenerate the title).
        var genreCount: [String: Int] = [:]
        for t in tracks { for g in t.genres { genreCount[g, default: 0] += 1 } }
        let topGenres = genreCount
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(2).map(\.key).sorted()
        if !topGenres.isEmpty { parts.append("g:\(topGenres.joined(separator: ","))") }

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
