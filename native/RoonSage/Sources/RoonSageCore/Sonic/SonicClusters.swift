import Accelerate
import Foundation

/// Sonic neighborhoods — k-means over the CLAP embeddings to discover the
/// natural "rooms" in a library (a late-night ambient corner, a peak-time house
/// corner, a singer-songwriter corner…), each becoming its own station. Unlike
/// the genre/mood buckets (which slice on metadata), these emerge purely from how
/// the music *sounds*, so they surface coherent pockets the tags never named.
///
/// Deterministic: farthest-first seeding + argmax assignment (lowest index wins
/// ties), no RNG — so the same library yields the same neighborhoods across runs.
/// Assignment is one `vDSP_mmul` (points · centroidsᵀ) per iteration.
public enum SonicClusters {

    public struct Cluster: Sendable {
        public let id: String          // stable medoid-derived key, not the volatile k-means index
        public let label: String
        public let memberIds: [String]
        public var size: Int { memberIds.count }
    }

    /// Cluster the embedded tracks. `genresById` (track id → Roon genres) labels
    /// each neighborhood by its dominant genre, falling back to a dominant tag or
    /// mood. Returns clusters sorted largest-first; `[]` when too few embeddings.
    public static func compute(
        tracks: [DatabaseManager.SonicTrack],
        index: VectorIndex,
        genresById: [String: Set<String>],
        maxIters: Int = 12
    ) -> [Cluster] {
        struct Pt { let track: DatabaseManager.SonicTrack; let vec: [Float] }
        let pts: [Pt] = tracks.compactMap { t in
            guard let v = index.embedding(forId: t.id) else { return nil }
            return Pt(track: t, vec: v)
        }
        let n = pts.count
        guard n >= 16 else { return [] }
        let dim = pts[0].vec.count

        // Flat point matrix (n×dim), row-major — rows are already unit vectors.
        var M = [Float](repeating: 0, count: n * dim)
        for (i, p) in pts.enumerated() { M.replaceSubrange(i * dim..<(i + 1) * dim, with: p.vec) }

        // AudioMuse-stijl kwaliteitszoektocht (gap A): probeer een k-BEREIK en
        // houd de clustering met de beste composietscore (geometrie + moods) —
        // i.p.v. één vaste k≈√(n/2). Deterministisch: vaste kandidaten, prefix-
        // stabiele farthest-first seeds; bij gelijke score wint de laagste k
        // (strikte >-vergelijking), dus de stabielste indeling.
        // n=17 -> kandidaten [6,8,10,12,14,16]; n>=21 -> [6,8,…,20].
        let vecs = pts.map(\.vec)
        let seedRows = farthestFirstSeeds(vecs: vecs, maxK: min(20, n - 1))
        var candidates = Array(stride(from: 6, through: 20, by: 2))
            .filter { n > $0 && $0 <= seedRows.count }
        if candidates.isEmpty, seedRows.count >= 2 {
            // Homogene/kleine library: minder onderscheiden sonische richtingen
            // dan de kleinste kandidaat — cluster met de seeds die er wél zijn
            // (het pre-sweep gedrag; nooit voorbij seedRows indexeren).
            candidates = [seedRows.count]
        }
        guard !candidates.isEmpty else { return [] }

        // Dominante mood per punt (zelfde 0.3-drempel als de labeling) voedt de
        // purity/diversity-termen van de score.
        let dominantMoods: [String?] = pts.map { p in
            guard let top = p.track.moods.max(by: { $0.value < $1.value }), top.value >= 0.3
            else { return nil }
            return top.key.lowercased()
        }

        var bestRun: (score: Double, assign: [Int], centroids: [[Float]])?
        for k in candidates {
            let run = runKMeans(M: M, vecs: vecs, seeds: Array(seedRows.prefix(k)),
                                dim: dim, maxIters: maxIters)
            guard run.centroids.count >= 2 else { continue }
            let s = clusteringScore(vecs: vecs, dominantMoods: dominantMoods,
                                    assign: run.assign, centroids: run.centroids)
            if bestRun == nil || s > bestRun!.score { bestRun = (s, run.assign, run.centroids) }
        }
        guard let best = bestRun else { return [] }
        let centroids = best.centroids
        let kActual = centroids.count
        let assign = best.assign

        var membersByC = [[Int]](repeating: [], count: kActual)
        for i in 0..<n where assign[i] >= 0 { membersByC[assign[i]].append(i) }

        var out: [Cluster] = []
        for c in 0..<kActual where !membersByC[c].isEmpty {
            let memberRows = membersByC[c]
            let members = memberRows.map { pts[$0].track }
            // Stable id from the cluster medoid (the member nearest the centroid).
            // The raw k-means index shifts as the library grows — keying the bucket
            // (and its persisted Qobuz selection) on that would silently break; the
            // medoid track is a far steadier anchor for "this neighborhood".
            let cen = centroids[c]
            let medoidRow = memberRows.max { dot(pts[$0].vec, cen) < dot(pts[$1].vec, cen) } ?? memberRows[0]
            let mt = pts[medoidRow].track
            let anchor = mt.matchKey.isEmpty ? mt.id : mt.matchKey
            out.append(Cluster(id: String(fnv1a(anchor) % 1_000_000),
                               label: label(for: members, genresById: genresById, index: c),
                               memberIds: members.map(\.id)))
        }
        return out.sorted { $0.size > $1.size }
    }

    // MARK: - k-means-kern + kwaliteitsscore (gap A)

    /// Farthest-first seeding — deterministisch én prefix-stabiel: de reeks
    /// voor k=20 begint met die voor k=6, dus één berekening volstaat voor de
    /// hele k-sweep. Kan minder dan `maxK` seeds teruggeven wanneer de library
    /// minder onderscheiden sonische richtingen heeft (homogeen, of exacte
    /// duplicaat-embeddings van remasters die de dedup overleven).
    private static func farthestFirstSeeds(vecs: [[Float]], maxK: Int) -> [Int] {
        let n = vecs.count
        var seeds = [0]
        var minDistToChosen = [Float](repeating: Float.greatestFiniteMagnitude, count: n)
        while seeds.count < maxK {
            let last = vecs[seeds.last!]
            for i in 0..<n {
                let d = 1 - dot(vecs[i], last)
                if d < minDistToChosen[i] { minDistToChosen[i] = d }
            }
            // Pick the farthest (max min-distance); lowest index breaks ties.
            var best = 0; var bestD: Float = -1
            for i in 0..<n where minDistToChosen[i] > bestD { bestD = minDistToChosen[i]; best = i }
            if seeds.contains(best) { break }
            seeds.append(best)
        }
        return seeds
    }

    /// Eén deterministische k-means-run: argmax-assignment via één `vDSP_mmul`
    /// per iteratie, L2-genormaliseerde centroid-updates, lege clusters houden
    /// hun oude centroid. (De kern die vóór gap A inline in `compute` stond.)
    private static func runKMeans(M: [Float], vecs: [[Float]], seeds: [Int],
                                  dim: Int, maxIters: Int)
        -> (assign: [Int], centroids: [[Float]]) {
        let n = vecs.count
        var centroids: [[Float]] = seeds.map { vecs[$0] }
        let kActual = centroids.count
        var assign = [Int](repeating: -1, count: n)
        guard kActual >= 1 else { return (assign, centroids) }
        for _ in 0..<maxIters {
            // B (dim×kActual): B[d*kActual + c] = centroids[c][d]; scores = M·B (n×kActual).
            var B = [Float](repeating: 0, count: dim * kActual)
            for c in 0..<kActual {
                let cen = centroids[c]
                for d in 0..<dim { B[d * kActual + c] = cen[d] }
            }
            var scores = [Float](repeating: 0, count: n * kActual)
            M.withUnsafeBufferPointer { mp in
                B.withUnsafeBufferPointer { bp in
                    scores.withUnsafeMutableBufferPointer { sp in
                        vDSP_mmul(mp.baseAddress!, 1, bp.baseAddress!, 1, sp.baseAddress!, 1,
                                  vDSP_Length(n), vDSP_Length(kActual), vDSP_Length(dim))
                    }
                }
            }
            var changed = false
            for i in 0..<n {
                let base = i * kActual
                var best = 0; var bestS = -Float.greatestFiniteMagnitude
                for c in 0..<kActual where scores[base + c] > bestS { bestS = scores[base + c]; best = c }
                if assign[i] != best { assign[i] = best; changed = true }
            }
            if !changed { break }
            // Recompute centroids = L2-normalized mean of members; keep old if empty.
            var sums = [[Float]](repeating: [Float](repeating: 0, count: dim), count: kActual)
            var counts = [Int](repeating: 0, count: kActual)
            for i in 0..<n {
                let c = assign[i]; counts[c] += 1
                sums[c].withUnsafeMutableBufferPointer { sp in
                    vecs[i].withUnsafeBufferPointer { vp in
                        vDSP_vadd(sp.baseAddress!, 1, vp.baseAddress!, 1, sp.baseAddress!, 1, vDSP_Length(dim))
                    }
                }
            }
            for c in 0..<kActual where counts[c] > 0 { centroids[c] = VectorIndex.normalized(sums[c]) }
        }
        return (assign, centroids)
    }

    /// Composietscore ≈ AudioMuse's clustering-fitness, deterministisch, O(n·k):
    /// - centroid-silhouette: cosinus met de eigen centroid minus de beste
    ///   andere (schaalbare benadering van de klassieke silhouette);
    /// - mood-purity: aandeel ge-mood-e leden dat de cluster-dominante mood
    ///   deelt (AudioMuse's purity);
    /// - mood-diversiteit: unieke cluster-dominante moods (AudioMuse's
    ///   diversity), genormaliseerd op het 6-mood-vocabulaire;
    /// - kleine-cluster-penalty: fractie clusters onder max(4, n/1000) leden.
    /// Gewichten heuristisch (0.5/0.3/0.2/−0.1): geometrie leidt, moods sturen
    /// bij. Zonder moods (geen CLAP) beslist de silhouette alleen.
    static func clusteringScore(vecs: [[Float]], dominantMoods: [String?],
                                assign: [Int], centroids: [[Float]]) -> Double {
        let n = vecs.count
        let k = centroids.count
        guard n > 0, k >= 2, assign.count == n, dominantMoods.count == n else {
            return -Double.infinity
        }

        var sil = 0.0
        for i in 0..<n {
            let own = dot(vecs[i], centroids[assign[i]])
            var other = -Float.greatestFiniteMagnitude
            for c in 0..<k where c != assign[i] {
                let s = dot(vecs[i], centroids[c])
                if s > other { other = s }
            }
            sil += Double(own - other)
        }
        sil /= Double(n)

        var moodCounts = [[String: Int]](repeating: [:], count: k)
        var sizes = [Int](repeating: 0, count: k)
        for i in 0..<n {
            sizes[assign[i]] += 1
            if let m = dominantMoods[i] { moodCounts[assign[i]][m, default: 0] += 1 }
        }
        var pureHits = 0, mooded = 0
        var clusterMoods = Set<String>()
        for c in 0..<k {
            let total = moodCounts[c].values.reduce(0, +)
            mooded += total
            if let top = moodCounts[c].max(by: { $0.value < $1.value }) {
                pureHits += top.value
                clusterMoods.insert(top.key)
            }
        }
        let purity = mooded > 0 ? Double(pureHits) / Double(mooded) : 0
        let diversity = Double(clusterMoods.count) / Double(min(k, 6))

        let minSize = max(4, n / 1000)
        let small = sizes.filter { $0 > 0 && $0 < minSize }.count
        let smallFrac = Double(small) / Double(k)

        return 0.5 * sil + 0.3 * purity + 0.2 * diversity - 0.1 * smallFrac
    }

    // MARK: - Labeling

    /// Name a neighborhood by its dominant Roon genre (if it covers ≥30% of the
    /// cluster), else a *corroborated, localized* analyzer tag, else dominant
    /// mood, else a fallback. Also reused by `SonicDNA.cores` so taste cores and
    /// sonic neighborhoods are named by one set of rules.
    ///
    /// The tag path used to emit the single most-frequent raw tag verbatim —
    /// which is how a Qobuz playlist ended up named "RoonSage · Acoustic" on
    /// non-acoustic music. Now a tag only names a neighborhood when it (a)
    /// covers ≥40% of members (not a mere plurality of noise), (b) has a Dutch
    /// display form, and (c) isn't contradicted by the cluster's *measured*
    /// attributes (an "acoustic" tag on a measured-electronic cluster is
    /// rejected). Tags failing any gate fall through to the next candidate,
    /// then to the mood path — never to a bare English word.
    static func label(
        for members: [DatabaseManager.SonicTrack],
        genresById: [String: Set<String>], index c: Int,
        fallback: String = "Sonische buurt"
    ) -> String {
        let size = max(1, members.count)
        let threshold = max(2, size * 3 / 10)

        // Dominant genre (keep first-seen casing).
        var genreCount: [String: Int] = [:]
        var genreLabel: [String: String] = [:]
        for m in members {
            for g in genresById[m.id] ?? [] {
                let key = g.lowercased()
                guard !key.isEmpty else { continue }
                genreCount[key, default: 0] += 1
                if genreLabel[key] == nil { genreLabel[key] = g }
            }
        }
        if let top = genreCount.max(by: { $0.value < $1.value }), top.value >= threshold {
            return genreLabel[top.key] ?? top.key.capitalized
        }

        // Dominant mood (argmax per track) — computed up front so the tag path
        // can compose "Tag · Mood" when both are clear.
        var moodCount: [String: Int] = [:]
        for m in members {
            if let top = m.moods.max(by: { $0.value < $1.value }), top.value >= 0.3 {
                moodCount[top.key.lowercased(), default: 0] += 1
            }
        }
        let topMood = moodCount.max(by: { $0.value < $1.value })

        // Corroborated tag: ≥40% coverage, localized, not contradicted by the
        // measured attributes. Walk candidates by count so a rejected top tag
        // doesn't kill the whole path.
        let tagThreshold = max(2, size * 2 / 5)
        var tagCount: [String: Int] = [:]
        for m in members { for t in m.tags { tagCount[t.lowercased(), default: 0] += 1 } }
        let stats = TitleGrounding.SelectionStats.compute(members)
        for (tag, count) in tagCount.sorted(by: { $0.value > $1.value }) {
            guard count >= tagThreshold else { break }
            guard let dutch = tagName(tag) else { continue }
            guard TitleGrounding.violations(title: dutch, stats: stats).isEmpty else { continue }
            // Compose with a clear dominant mood when it adds information.
            if let (moodKey, moodN) = topMood, moodN >= threshold {
                let mood = moodName(moodKey)
                if mood.lowercased() != dutch.lowercased() { return "\(dutch) · \(mood.lowercased())" }
            }
            return dutch
        }

        if let (moodKey, _) = topMood {
            return moodName(moodKey)
        }
        return "\(fallback) \(c + 1)"
    }

    static func moodName(_ key: String) -> String {
        let map: [String: String] = [
            "happy": "Vrolijk", "sad": "Melancholisch", "relaxed": "Ontspannen",
            "aggressive": "Stevig", "party": "Feestelijk", "danceable": "Dansbaar",
        ]
        return map[key] ?? key.capitalized
    }

    /// Dutch display form for the analyzer/MB tags we're willing to put in a
    /// user-facing station name. Anything not in this list never names a station
    /// — an unvetted free-text tag ("female vocalists", "seen live", …) reads as
    /// noise, and an untranslated one as a bug.
    static func tagName(_ key: String) -> String? {
        let map: [String: String] = [
            "acoustic": "Akoestisch", "unplugged": "Akoestisch",
            "electronic": "Elektronisch", "electronica": "Elektronisch",
            "ambient": "Ambient", "downtempo": "Downtempo", "chillout": "Chill-out",
            "chill": "Rustig", "mellow": "Rustig", "calm": "Kalm",
            "atmospheric": "Atmosferisch", "dreamy": "Dromerig", "ethereal": "Etherisch",
            "dark": "Donker", "melancholic": "Melancholisch", "melancholy": "Melancholisch",
            "uplifting": "Opwekkend", "upbeat": "Opgewekt", "feelgood": "Feelgood",
            "energetic": "Energiek", "high-energy": "Energiek", "driving": "Stuwend",
            "peak-time": "Piekuur", "warmup": "Warm-up", "warm-up": "Warm-up",
            "groovy": "Groovy", "funky": "Funky", "soulful": "Soulvol",
            "jazzy": "Jazzy", "bluesy": "Bluesy", "folky": "Folky",
            "melodic": "Melodisch", "minimal": "Minimaal", "deep": "Deep",
            "instrumental": "Instrumentaal", "vocal": "Vocaal",
            "romantic": "Romantisch", "epic": "Episch", "cinematic": "Filmisch",
            "psychedelic": "Psychedelisch", "experimental": "Experimenteel",
            "lo-fi": "Lo-fi", "lofi": "Lo-fi", "organic": "Organisch",
            "danceable": "Dansbaar", "hypnotic": "Hypnotisch",
        ]
        return map[key]
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var d: Float = 0
        vDSP_dotpr(a, 1, b, 1, &d, vDSP_Length(min(a.count, b.count)))
        return d
    }

    /// FNV-1a 64-bit — a stable string hash for the medoid-derived cluster id
    /// (`String.hashValue` is per-process salted and would reshuffle every launch).
    private static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
