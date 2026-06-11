import AudioAnalysis
import Foundation

/// Measures analyzer accuracy against a reference set so DSP changes can be
/// judged by numbers, not guesswork. Pure comparison logic (no I/O) — the CLI
/// `validate` command supplies analyzed-vs-reference pairs and prints the report.
///
/// Reference CSV columns: `artist,title,bpm,camelot` (the analyzer's own output
/// shape; also exportable from the old Docker `track_audio_features` table).
public enum AccuracyValidator {

    // MARK: BPM

    public enum BPMVerdict: String, Sendable {
        case exact          // within ±tol of the reference
        case halfTempo      // analyzed ≈ reference / 2  (octave error)
        case doubleTempo    // analyzed ≈ reference × 2  (octave error)
        case off            // none of the above
    }

    /// Classify an analyzed BPM against a reference. `tol` is a fractional
    /// tolerance (0.04 ⇒ ±4%), generous enough for interpolation jitter.
    public static func classifyBPM(analyzed: Double, reference: Double, tol: Double = 0.04) -> BPMVerdict {
        guard analyzed > 0, reference > 0 else { return .off }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= b * tol }
        if near(analyzed, reference) { return .exact }
        if near(analyzed, reference / 2) { return .halfTempo }
        if near(analyzed, reference * 2) { return .doubleTempo }
        return .off
    }

    // MARK: Key (Camelot)

    public enum KeyVerdict: String, Sendable {
        case exact          // same Camelot code
        case relative       // same number, swapped letter — relative major/minor (8A↔8B)
        case neighbor       // number ±1, same letter — perfect-fifth neighbour on the wheel
        case off            // unrelated (or unparseable)
    }

    /// Parse a Camelot code like "8A" → (number 1…12, isB).
    static func parseCamelot(_ s: String) -> (n: Int, isB: Bool)? {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        guard let last = t.last, last == "A" || last == "B" else { return nil }
        guard let n = Int(t.dropLast()), (1...12).contains(n) else { return nil }
        return (n, last == "B")
    }

    public static func classifyKey(analyzed: String, reference: String) -> KeyVerdict {
        guard let a = parseCamelot(analyzed), let r = parseCamelot(reference) else { return .off }
        if a == r { return .exact }
        if a.n == r.n, a.isB != r.isB { return .relative }
        // ±1 around the 12-hour wheel, same letter.
        let up = r.n % 12 + 1
        let down = (r.n + 10) % 12 + 1
        if a.isB == r.isB, a.n == up || a.n == down { return .neighbor }
        return .off
    }

    // MARK: Aggregate report

    public struct Report: Sendable {
        public var compared = 0
        public var bpm: [BPMVerdict: Int] = [:]
        public var key: [KeyVerdict: Int] = [:]

        public init() {}

        public mutating func add(analyzedBPM: Double, refBPM: Double, analyzedCamelot: String, refCamelot: String) {
            compared += 1
            bpm[classifyBPM(analyzed: analyzedBPM, reference: refBPM), default: 0] += 1
            key[classifyKey(analyzed: analyzedCamelot, reference: refCamelot), default: 0] += 1
        }

        private func pct(_ n: Int) -> String {
            compared == 0 ? "0%" : String(format: "%.1f%%", Double(n) / Double(compared) * 100)
        }

        public func formatted() -> String {
            let bExact = bpm[.exact, default: 0]
            let bHalf = bpm[.halfTempo, default: 0], bDouble = bpm[.doubleTempo, default: 0]
            let bOff = bpm[.off, default: 0]
            let kExact = key[.exact, default: 0], kRel = key[.relative, default: 0]
            let kNbr = key[.neighbor, default: 0], kOff = key[.off, default: 0]
            return """
            Accuracy over \(compared) tracks
            ── BPM ───────────────────────────────
              exact (±4%) : \(bExact)  (\(pct(bExact)))
              half-tempo  : \(bHalf)  (\(pct(bHalf)))      ← octave error
              double-tempo: \(bDouble)  (\(pct(bDouble)))      ← octave error
              off         : \(bOff)  (\(pct(bOff)))
            ── Key (Camelot) ─────────────────────
              exact       : \(kExact)  (\(pct(kExact)))
              relative    : \(kRel)  (\(pct(kRel)))      ← major/minor swap
              neighbour   : \(kNbr)  (\(pct(kNbr)))      ← ±1 on the wheel
              off         : \(kOff)  (\(pct(kOff)))
            """
        }
    }

    // MARK: Reference CSV

    public struct ReferenceRow: Sendable {
        public var matchKey: String
        public var bpm: Double
        public var camelot: String
    }

    /// Parse `artist,title,bpm,camelot` rows (header optional) into reference
    /// rows keyed by `TrackIdentity.matchKey`. Minimal RFC-4180 quoting support.
    public static func parseReferenceCSV(_ text: String) -> [String: ReferenceRow] {
        var out: [String: ReferenceRow] = [:]
        for (i, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            let cols = parseCSVLine(String(line))
            guard cols.count >= 4 else { continue }
            // Skip a header row if present.
            if i == 0, Double(cols[2]) == nil { continue }
            guard let bpm = Double(cols[2].trimmingCharacters(in: .whitespaces)) else { continue }
            let key = TrackIdentity.matchKey(artist: cols[0], album: nil, title: cols[1])
            out[key] = ReferenceRow(matchKey: key, bpm: bpm,
                                    camelot: cols[3].trimmingCharacters(in: .whitespaces))
        }
        return out
    }

    static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var cur = ""
        var inQuotes = false
        var it = line.makeIterator()
        var pending: Character? = nil
        func next() -> Character? { if let p = pending { pending = nil; return p }; return it.next() }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = it.next() { if n == "\"" { cur.append("\"") } else { inQuotes = false; pending = n } }
                    else { inQuotes = false }
                } else { cur.append(c) }
            } else if c == "\"" { inQuotes = true }
            else if c == "," { fields.append(cur); cur = "" }
            else { cur.append(c) }
        }
        fields.append(cur)
        return fields
    }
}
