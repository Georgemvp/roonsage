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
}
