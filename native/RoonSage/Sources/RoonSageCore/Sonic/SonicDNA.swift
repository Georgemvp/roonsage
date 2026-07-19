import Accelerate
import Foundation

/// The engine behind **Sonic DNA** — a recency-weighted portrait of the user's
/// taste, computed from play history + likes over the analyzed library.
///
/// Everything here is pure and deterministic (given `now`), so it's unit-testable
/// without a database. The orchestrator (`RoonClient.sonicFingerprint`) does the
/// DB/HTTP I/O and hands the raw ingredients in.
///
/// Three layers:
///  1. **Seeds** — the tracks that define "you", each carrying a weight
///     `log(1 + plays) · exp(−ageDays / halfLife)` (heavy rotation matters,
///     recent listening matters more). Likes join with a flat bonus; disliked
///     tracks never shape the DNA.
///  2. **Profile** — weighted radar axes over the seeds (energy, danceability,
///     valence, acousticness, adventure, mainstream) + genre/mood DNA. Computed
///     for all-time and for a recent window, so the UI can show *evolution*.
///  3. **Cores** ("smaakkernen") — weighted k-means over the seeds' CLAP
///     embeddings. One centroid of a multimodal taste points at an empty middle;
///     3–5 cores describe where the listening actually lives.
public enum SonicDNA {

    // MARK: - Play stats (shared with the /play-stats share endpoint)

    /// One row of listening history aggregated per content key. Codable so the
    /// share server can serve it to thin clients verbatim.
    public struct PlayStat: Sendable, Codable {
        public var matchKey: String
        public var count: Int
        public var lastPlayed: String   // ISO8601; "" when unknown
        public init(matchKey: String, count: Int, lastPlayed: String) {
            self.matchKey = matchKey; self.count = count; self.lastPlayed = lastPlayed
        }
    }

    // MARK: - Seeds

    public struct Seed: Sendable {
        public var track: DatabaseManager.SonicTrack
        public var weight: Double
        public init(track: DatabaseManager.SonicTrack, weight: Double) {
            self.track = track; self.weight = weight
        }
    }

    /// Recency-weighted play weight — the same curve as `TasteVector`, so the
    /// DNA and the stations agree on what "your taste now" means.
    public static func playWeight(count: Int, lastPlayed: String, now: Date = Date()) -> Double {
        let recency: Double
        if let d = ISO8601DateFormatter().date(from: lastPlayed) {
            let ageDays = max(0, now.timeIntervalSince(d) / 86_400)
            recency = exp(-ageDays / TasteVector.halfLifeDays)
        } else {
            recency = 0.5   // unknown timestamp → middling weight
        }
        return log(1 + Double(count)) * recency
    }

    /// The weighted seed set: most-played (recency-weighted) analyzed tracks,
    /// plus thumbed-up tracks (flat like-bonus), minus thumbed-down ones —
    /// a disliked track never defines the DNA, no matter how often it played.
    /// Sorted heaviest-first (RadioEngine's anchor cap then keeps the tracks
    /// that matter most) and capped to `limit`.
    public static func selectSeeds(
        playStats: [PlayStat],
        byMatchKey: [String: DatabaseManager.SonicTrack],
        liked: Set<String>,
        disliked: Set<String>,
        limit: Int,
        now: Date = Date()
    ) -> [Seed] {
        var weightByKey: [String: Double] = [:]
        for s in playStats where !s.matchKey.isEmpty {
            guard !disliked.contains(s.matchKey) else { continue }
            weightByKey[s.matchKey, default: 0] += playWeight(count: s.count, lastPlayed: s.lastPlayed, now: now)
        }
        // Explicit likes are a strong "this is me" signal, plays or not.
        for key in liked where !disliked.contains(key) {
            weightByKey[key, default: 0] += TasteVector.likeBonus
        }
        return weightByKey
            .compactMap { key, w -> Seed? in
                guard let t = byMatchKey[key] else { return nil }
                return Seed(track: t, weight: w)
            }
            .sorted { $0.weight == $1.weight ? $0.track.id < $1.track.id : $0.weight > $1.weight }
            .prefix(max(1, limit))
            .map { $0 }
    }

    /// Deterministic library-wide fallback when there's no listening history
    /// yet: an evenly-strided sample (not "the first N rows", which is
    /// whatever order the cache happens to be in), each with equal weight.
    public static func librarySampleSeeds(
        _ library: [DatabaseManager.SonicTrack], limit: Int = 200
    ) -> [Seed] {
        guard !library.isEmpty else { return [] }
        let stride = max(1, library.count / max(1, limit))
        var out: [Seed] = []
        var i = 0
        while i < library.count && out.count < limit {
            out.append(Seed(track: library[i], weight: 1))
            i += stride
        }
        return out
    }

    // MARK: - Profile

    public struct GenreShare: Sendable, Equatable {
        public var name: String
        public var share: Double   // 0…1 of the seed weight carrying this genre
        public init(name: String, share: Double) { self.name = name; self.share = share }
    }

    public struct MoodShare: Sendable, Equatable {
        public var name: String    // localized display name ("Vrolijk", …)
        public var share: Double
        public init(name: String, share: Double) { self.name = name; self.share = share }
    }

    /// The weighted taste profile. Every axis is 0…1; axes whose underlying
    /// data is missing across the whole seed set sit at a neutral 0.5.
    public struct Profile: Sendable {
        public var energy: Double
        public var danceability: Double
        public var valence: Double        // "Zonnig" — happy ↔ melancholic
        public var acousticness: Double   // organic ↔ electronic
        public var adventure: Double      // artist diversity + sonic spread
        public var mainstream: Double     // global hits ↔ deep cuts
        public var avgBPM: Double
        public var tempo: Double          // avg BPM mapped 60→0, 180→1
        public var topGenres: [GenreShare]
        public var topMoods: [MoodShare]
        public var sampleCount: Int
        /// Radar axes in display order: (label, value 0…1).
        public var axes: [(String, Double)] {
            [("Energie", energy), ("Dansbaar", danceability), ("Zonnig", valence),
             ("Akoestisch", acousticness), ("Avontuur", adventure), ("Mainstream", mainstream)]
        }
    }

    /// Compute the weighted profile of `seeds`. `index` (when present) powers
    /// the sonic-spread half of the adventure axis; `genresById` powers the
    /// genre DNA (umbrella genres covering > 35% of the tagged library are
    /// dropped — they discriminate nothing); `library` provides the popularity
    /// range so "mainstream" is relative to what the user actually owns.
    public static func profile(
        seeds: [Seed],
        index: VectorIndex?,
        genresById: [String: Set<String>],
        library: [DatabaseManager.SonicTrack]
    ) -> Profile {
        let totalW = seeds.reduce(0) { $0 + $1.weight }
        guard !seeds.isEmpty, totalW > 0 else {
            return Profile(energy: 0.5, danceability: 0.5, valence: 0.5, acousticness: 0.5,
                           adventure: 0.5, mainstream: 0.5, avgBPM: 0, tempo: 0,
                           topGenres: [], topMoods: [], sampleCount: 0)
        }

        // Weighted mean over seeds that carry the value; neutral 0.5 when none do.
        func weightedMean(_ value: (DatabaseManager.SonicTrack) -> Double?) -> Double? {
            var sum = 0.0, w = 0.0
            for s in seeds {
                guard let v = value(s.track) else { continue }
                sum += v * s.weight; w += s.weight
            }
            return w > 0 ? sum / w : nil
        }

        let energy = weightedMean { $0.energySignal } ?? 0.5
        let dance = weightedMean { $0.attributes["danceability"].map(Double.init) } ?? 0.5
        let valence = weightedMean { $0.attributes["valence"].map(Double.init) } ?? 0.5
        let acoustic = weightedMean { $0.attributes["acousticness"].map(Double.init) } ?? 0.5

        // BPM
        let avgBPM = weightedMean { ($0.bpm ?? 0) > 0 ? $0.bpm : nil } ?? 0
        let tempo = min(1, max(0, (avgBPM - 60) / 120))

        // Mainstream: log-normalized Deezer rank over the LIBRARY's own range —
        // "mainstream" relative to this collection, not the global chart.
        let libPopLogs = library.compactMap { $0.popularity }.filter { $0 > 0 }.map { log10(Double($0) + 1) }
        let popLo = libPopLogs.min() ?? 0
        let popSpan = max(1e-6, (libPopLogs.max() ?? 0) - popLo)
        let mainstream = weightedMean { t in
            guard let p = t.popularity, p > 0 else { return nil }
            return min(1, max(0, (log10(Double(p) + 1) - popLo) / popSpan))
        } ?? 0.5

        // Adventure: half artist diversity, half sonic spread around the
        // weighted centroid (embeddings; falls back to diversity alone).
        var artists = Set<String>()
        for s in seeds { artists.insert((s.track.artist ?? "").lowercased()) }
        let diversity = min(1, Double(artists.count) / Double(seeds.count))
        var adventure = diversity
        if let index {
            let embedded = seeds.compactMap { s -> (emb: [Float], w: Double)? in
                guard let e = index.embedding(forId: s.track.id) else { return nil }
                return (e, s.weight)
            }
            if embedded.count >= 4,
               let centroid = VectorIndex.weightedCentroid(embedded.map { ($0.emb, Float($0.w)) }) {
                var spreadSum = 0.0, w = 0.0
                for e in embedded {
                    var d: Float = 0
                    vDSP_dotpr(e.emb, 1, centroid, 1, &d, vDSP_Length(min(e.emb.count, centroid.count)))
                    spreadSum += (1 - Double(max(-1, min(1, d)))) * e.w
                    w += e.w
                }
                // Typical CLAP cosine spread lives in ~0…0.5 — normalize there.
                let spread = min(1, (w > 0 ? spreadSum / w : 0) / 0.5)
                adventure = 0.5 * diversity + 0.5 * spread
            }
        }

        // Genre DNA: seed-weight share per genre, umbrella genres dropped.
        let umbrella = umbrellaGenres(genresById)
        var genreW: [String: Double] = [:]
        var genreLabel: [String: String] = [:]
        for s in seeds {
            for g in genresById[s.track.id] ?? [] {
                let key = g.lowercased()
                guard !key.isEmpty, !umbrella.contains(key) else { continue }
                genreW[key, default: 0] += s.weight
                if genreLabel[key] == nil { genreLabel[key] = g }
            }
        }
        let topGenres = genreW.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(5)
            .map { GenreShare(name: genreLabel[$0.key] ?? $0.key.capitalized, share: min(1, $0.value / totalW)) }

        // Mood DNA: weighted argmax mood per seed.
        var moodW: [String: Double] = [:]
        for s in seeds {
            if let top = s.track.moods.max(by: { $0.value < $1.value }), top.value >= 0.25 {
                moodW[top.key.lowercased(), default: 0] += s.weight
            }
        }
        let topMoods = moodW.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3)
            .map { MoodShare(name: SonicClusters.moodName($0.key), share: min(1, $0.value / totalW)) }

        return Profile(
            energy: min(1, max(0, energy)),
            danceability: min(1, max(0, dance)),
            valence: min(1, max(0, valence)),
            acousticness: min(1, max(0, acoustic)),
            adventure: min(1, max(0, adventure)),
            mainstream: min(1, max(0, mainstream)),
            avgBPM: avgBPM, tempo: tempo,
            topGenres: topGenres, topMoods: topMoods,
            sampleCount: seeds.count)
    }

    /// Genres carried by more than 35% of the genre-tagged tracks (e.g. Roon's
    /// "Pop/Rock") — matching almost everything, they say nothing about taste.
    static func umbrellaGenres(_ genresById: [String: Set<String>]) -> Set<String> {
        guard !genresById.isEmpty else { return [] }
        let total = max(1, genresById.count)
        var freq: [String: Int] = [:]
        for gs in genresById.values { for g in gs { freq[g.lowercased(), default: 0] += 1 } }
        return Set(freq.filter { Double($0.value) / Double(total) > 0.35 }.keys)
    }

    // MARK: - Evolution (recent window vs all-time)

    public struct AxisDelta: Sendable, Equatable {
        public var label: String    // "Energie", …
        public var delta: Double    // recent − allTime, −1…1
        public init(label: String, delta: Double) { self.label = label; self.delta = delta }
    }

    /// The axes where the recent window meaningfully departs from the all-time
    /// profile (|Δ| ≥ `threshold`), biggest movers first. Empty = "stabiel".
    public static func evolution(
        recent: Profile, allTime: Profile, threshold: Double = 0.06, limit: Int = 3
    ) -> [AxisDelta] {
        zip(recent.axes, allTime.axes)
            .map { AxisDelta(label: $0.0, delta: $0.1 - $1.1) }
            .filter { abs($0.delta) >= threshold }
            .sorted { abs($0.delta) > abs($1.delta) }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Taste cores ("smaakkernen")

    public struct Core: Sendable, Identifiable {
        public var id: String            // stable medoid-derived key
        public var label: String
        public var share: Double         // 0…1 of the total seed weight
        public var trackIds: [String]    // member track ids, heaviest first
        public var topArtists: [String]  // up to 3 display names
        public var centroid: [Float]     // L2-normalized query vector
    }

    /// Weighted k-means over the seeds' CLAP embeddings — the 3–5 places where
    /// the listening actually lives. Deterministic (farthest-first init, argmax
    /// assignment, lowest index breaks ties). `[]` when fewer than 12 seeds
    /// carry an embedding — too little signal for meaningful cores.
    public static func cores(
        seeds: [Seed],
        index: VectorIndex,
        genresById: [String: Set<String>],
        maxIters: Int = 12
    ) -> [Core] {
        struct Pt { let seed: Seed; let vec: [Float] }
        let pts: [Pt] = seeds.compactMap { s in
            guard let v = index.embedding(forId: s.track.id) else { return nil }
            return Pt(seed: s, vec: v)
        }
        let n = pts.count
        guard n >= 12 else { return [] }
        let dim = pts[0].vec.count
        let k = max(3, min(5, n / 10))
        guard n > k else { return [] }

        // Farthest-first init (identical strategy to SonicClusters, so the two
        // clusterings behave consistently across the app).
        var seedRows = [0]
        var minDist = [Float](repeating: .greatestFiniteMagnitude, count: n)
        while seedRows.count < k {
            let last = pts[seedRows.last!].vec
            for i in 0..<n {
                var d: Float = 0
                vDSP_dotpr(pts[i].vec, 1, last, 1, &d, vDSP_Length(dim))
                let dist = 1 - d
                if dist < minDist[i] { minDist[i] = dist }
            }
            var best = 0; var bestD: Float = -1
            for i in 0..<n where minDist[i] > bestD { bestD = minDist[i]; best = i }
            if seedRows.contains(best) { break }
            seedRows.append(best)
        }
        var centroids: [[Float]] = seedRows.map { pts[$0].vec }
        let kActual = centroids.count
        guard kActual >= 2 else { return [] }

        var assign = [Int](repeating: -1, count: n)
        for _ in 0..<maxIters {
            var changed = false
            for i in 0..<n {
                var best = 0; var bestS: Float = -.greatestFiniteMagnitude
                for c in 0..<kActual {
                    var s: Float = 0
                    vDSP_dotpr(pts[i].vec, 1, centroids[c], 1, &s, vDSP_Length(dim))
                    if s > bestS { bestS = s; best = c }
                }
                if assign[i] != best { assign[i] = best; changed = true }
            }
            if !changed { break }
            // Weighted centroid update — heavy-rotation members pull harder.
            var sums = [[Float]](repeating: [Float](repeating: 0, count: dim), count: kActual)
            var wsum = [Double](repeating: 0, count: kActual)
            for i in 0..<n {
                let c = assign[i]
                var w = Float(pts[i].seed.weight)
                var scaled = [Float](repeating: 0, count: dim)
                vDSP_vsmul(pts[i].vec, 1, &w, &scaled, 1, vDSP_Length(dim))
                sums[c].withUnsafeMutableBufferPointer { sp in
                    vDSP_vadd(sp.baseAddress!, 1, scaled, 1, sp.baseAddress!, 1, vDSP_Length(dim))
                }
                wsum[c] += pts[i].seed.weight
            }
            for c in 0..<kActual where wsum[c] > 0 { centroids[c] = VectorIndex.normalized(sums[c]) }
        }

        var membersByC = [[Int]](repeating: [], count: kActual)
        for i in 0..<n where assign[i] >= 0 { membersByC[assign[i]].append(i) }

        // Umbrella genres (e.g. Roon's "Pop/Rock", covering most of the library)
        // say nothing about a *sonic* pocket — and if kept they'd label every
        // core identically. Drop them before labeling.
        let umbrella = umbrellaGenres(genresById)

        // Build every core first (unlabeled), then assign labels in share order
        // so the biggest core gets its strongest distinctive label and no two
        // cores share a name.
        struct Draft {
            let id: String
            let share: Double
            let trackIds: [String]
            let topArtists: [String]
            let centroid: [Float]
            let candidates: [String]   // distinctive labels, best first
        }

        let totalW = max(1e-9, pts.reduce(0) { $0 + $1.seed.weight })
        var drafts: [Draft] = []
        for c in 0..<kActual {
            let rows = membersByC[c]
            guard rows.count >= 3 else { continue }   // a 1–2 track "core" is noise
            let members = rows.map { pts[$0] }.sorted { $0.seed.weight > $1.seed.weight }
            let coreW = members.reduce(0) { $0 + $1.seed.weight }

            // Stable id from the medoid (nearest-to-centroid member).
            let cen = centroids[c]
            let medoid = members.max { a, b in
                var da: Float = 0, db: Float = 0
                vDSP_dotpr(a.vec, 1, cen, 1, &da, vDSP_Length(dim))
                vDSP_dotpr(b.vec, 1, cen, 1, &db, vDSP_Length(dim))
                return da < db
            } ?? members[0]
            let anchor = medoid.seed.track.matchKey.isEmpty ? medoid.seed.track.id : medoid.seed.track.matchKey

            // Top artists by member weight.
            var artistW: [String: Double] = [:]
            var artistLabel: [String: String] = [:]
            for m in members {
                guard let a = m.seed.track.artist, !a.isEmpty else { continue }
                artistW[a.lowercased(), default: 0] += m.seed.weight
                if artistLabel[a.lowercased()] == nil { artistLabel[a.lowercased()] = a }
            }
            let topArtists = artistW.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(3).compactMap { artistLabel[$0.key] }

            drafts.append(Draft(
                id: String(fnv1a(anchor) % 1_000_000),
                share: min(1, coreW / totalW),
                trackIds: members.map { $0.seed.track.id },
                topArtists: topArtists,
                centroid: cen,
                candidates: labelCandidates(
                    members: members.map { (track: $0.seed.track, weight: $0.seed.weight) },
                    genresById: genresById, umbrella: umbrella)))
        }

        drafts.sort { $0.share > $1.share }
        var used = Set<String>()
        var out: [Core] = []
        for (i, d) in drafts.enumerated() {
            // First distinctive candidate not already taken by a bigger core;
            // fall back to the lead artist, then a numbered "Smaakkern".
            let label = d.candidates.first { !used.contains($0.lowercased()) }
                ?? d.topArtists.first { !used.contains($0.lowercased()) }
                ?? "Smaakkern \(i + 1)"
            used.insert(label.lowercased())
            out.append(Core(id: d.id, label: label, share: d.share,
                            trackIds: d.trackIds, topArtists: d.topArtists,
                            centroid: d.centroid))
        }
        return out
    }

    /// Distinctive labels for a taste core, most-characteristic first:
    /// discriminating genres (umbrella dropped) by member weight, then dominant
    /// moods, then analyzer tags. The caller picks the first not already used by
    /// a bigger core, so sibling cores never collapse to the same name.
    static func labelCandidates(
        members: [(track: DatabaseManager.SonicTrack, weight: Double)],
        genresById: [String: Set<String>],
        umbrella: Set<String>
    ) -> [String] {
        var out: [String] = []

        var genreW: [String: Double] = [:]
        var genreLabel: [String: String] = [:]
        for m in members {
            for g in genresById[m.track.id] ?? [] {
                let key = g.lowercased()
                guard !key.isEmpty, !umbrella.contains(key) else { continue }
                genreW[key, default: 0] += m.weight
                if genreLabel[key] == nil { genreLabel[key] = g }
            }
        }
        for (k, _) in genreW.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
            out.append(genreLabel[k] ?? k.capitalized)
        }

        var moodW: [String: Double] = [:]
        for m in members {
            if let top = m.track.moods.max(by: { $0.value < $1.value }), top.value >= 0.25 {
                moodW[top.key.lowercased(), default: 0] += m.weight
            }
        }
        for (k, _) in moodW.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
            out.append(SonicClusters.moodName(k))
        }

        var tagW: [String: Double] = [:]
        for m in members { for t in m.track.tags { tagW[t.lowercased(), default: 0] += m.weight } }
        for (k, _) in tagW.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
            out.append(k.capitalized)
        }
        return out
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}

extension VectorIndex {
    /// Weighted, L2-normalized centroid over explicit (vector, weight) pairs —
    /// unlike `centroid(ofIds:weights:)` there's no id lookup, so weights can't
    /// silently misalign when an id is missing from the index.
    static func weightedCentroid(_ items: [(vec: [Float], w: Float)]) -> [Float]? {
        guard let dim = items.first?.vec.count, dim > 0 else { return nil }
        var acc = [Float](repeating: 0, count: dim)
        var any = false
        for item in items where item.w > 0 {
            var w = item.w
            var scaled = [Float](repeating: 0, count: dim)
            vDSP_vsmul(item.vec, 1, &w, &scaled, 1, vDSP_Length(dim))
            vDSP_vadd(acc, 1, scaled, 1, &acc, 1, vDSP_Length(dim))
            any = true
        }
        guard any else { return nil }
        return normalized(acc)
    }
}
