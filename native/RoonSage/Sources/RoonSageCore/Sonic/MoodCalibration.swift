import Foundation

/// Gap G (AudioMuse-audit): mood-kalibratie t.o.v. de eigen bibliotheek.
///
/// CLAP's zero-shot mood-cosines hebben per label een eigen basislijn (tekst-
/// prior): "danceable" scoort bibliotheekbreed structureel hoger dan "sad",
/// waardoor rauwe argmax die labels overbedeelt. Z-scores per label — t.o.v.
/// de verdeling over de hele bibliotheek — meten "waar is déze track ongewoon
/// hoog op". Het equivalent van AudioMuse's mood-centroids-kalibratie, maar
/// berekend uit de eigen bibliotheek en dus altijd actueel; zelfde filosofie
/// als de arousal-percentiel-kalibratie in `TitleGrounding`.
///
/// Deterministisch: alle iteraties over mood-dictionaries lopen op gesorteerde
/// sleutels, dus gelijke input → gelijke toewijzing.
public struct MoodCalibration: Sendable {
    let stats: [String: (mean: Float, std: Float)]

    /// Per-mood gemiddelde + standaarddeviatie over `tracks`. Labels met
    /// minder dan 8 waarnemingen krijgen geen statistiek (te ruizig).
    public init(tracks: [DatabaseManager.SonicTrack]) {
        var sums: [String: (n: Int, sum: Double, sumSq: Double)] = [:]
        for t in tracks {
            for (k, v) in t.moods.sorted(by: { $0.key < $1.key }) {
                let key = k.lowercased()
                var s = sums[key] ?? (0, 0, 0)
                s.n += 1
                s.sum += Double(v)
                s.sumSq += Double(v) * Double(v)
                sums[key] = s
            }
        }
        var out: [String: (mean: Float, std: Float)] = [:]
        for (k, s) in sums where s.n >= 8 {
            let mean = s.sum / Double(s.n)
            let variance = max(0, s.sumSq / Double(s.n) - mean * mean)
            out[k] = (Float(mean), Float(variance.squareRoot()))
        }
        stats = out
    }

    /// Dominante gekalibreerde mood: het label met de hoogste z-score, mits
    /// die ≥ `zFloor` — een track die nergens bovengemiddeld op scoort krijgt
    /// géén mood (vlakke profielen horen in geen enkel mood-station). Zonder
    /// bruikbare statistiek (kleine bibliotheek, std ≈ 0) valt hij terug op de
    /// oude rauwe argmax met 0.3-floor.
    public func dominantMood(_ moods: [String: Float], zFloor: Float = 0.5) -> String? {
        var bestKey: String?
        var bestZ = -Float.greatestFiniteMagnitude
        var usable = false
        for (k, v) in moods.sorted(by: { $0.key < $1.key }) {
            let key = k.lowercased()
            guard let st = stats[key], st.std > 1e-4 else { continue }
            usable = true
            let z = (v - st.mean) / st.std
            if z > bestZ { bestZ = z; bestKey = key }
        }
        if usable { return bestZ >= zFloor ? bestKey : nil }
        guard let top = moods.max(by: { $0.value < $1.value }), top.value >= 0.3 else { return nil }
        return top.key.lowercased()
    }

    /// Hoort deze track in het station van `mood`? De gekalibreerde tegenhanger
    /// van de losse `value >= 0.3`-test die op vijf plekken gedupliceerd stond.
    ///
    /// Waarom die 0.3 fout was: het is een ABSOLUTE drempel op een as met een
    /// per-label tekst-prior. "danceable" haalt 'm bibliotheekbreed, "sad"
    /// bijna nooit — dus vulden de dansstations zich met alles en bleven de
    /// droevige leeg. De z-score meet in plaats daarvan "ongewoon hoog vóór
    /// déze bibliotheek", wat per label hetzelfde betekent.
    ///
    /// De dominante mood telt altijd mee: een track die nergens anders hoger
    /// op scoort hoort in dat station, ook als de z-score net onder de vloer
    /// blijft. Zonder bruikbare statistiek valt hij terug op de oude 0.3.
    /// `matches` voor call-sites die alleen een OPTIONELE kalibratie hebben
    /// (kleine of nog niet geladen bibliotheek). Zonder kalibratie exact het
    /// oude gedrag — dominante mood, of een score ≥ 0.3 — zodat het wegvallen
    /// van de statistiek nooit een station leegtrekt.
    public static func matches(_ mood: String, in moods: [String: Float],
                               calibration: MoodCalibration?, zFloor: Float = 0.5) -> Bool {
        if let c = calibration { return c.matches(mood, in: moods, zFloor: zFloor) }
        let key = mood.lowercased()
        if moods.max(by: { $0.value < $1.value })?.key.lowercased() == key { return true }
        return moods.first { $0.key.lowercased() == key }.map { $0.value >= 0.3 } ?? false
    }

    public func matches(_ mood: String, in moods: [String: Float], zFloor: Float = 0.5) -> Bool {
        let key = mood.lowercased()
        if dominantMood(moods, zFloor: zFloor) == key { return true }
        guard let st = stats[key], st.std > 1e-4 else {
            return moods.first { $0.key.lowercased() == key }.map { $0.value >= 0.3 } ?? false
        }
        guard let v = moods.first(where: { $0.key.lowercased() == key })?.value else { return false }
        return (v - st.mean) / st.std >= zFloor
    }
}
