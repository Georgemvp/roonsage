import Accelerate
import Foundation

/// The "smart radio" ranker — the heart of the Plexamp-class stations.
///
/// Where `SonicEngine.nearest(toSeeds:)` simply averages the seed embeddings into
/// one centroid and returns the cosine-nearest tracks, `RadioEngine` adds the four
/// things that make a station feel *curated* rather than "nearest 250":
///
///  1. **Multi-anchor relevance.** A seed set that spans ballads *and* bangers
///     has a centroid stuck in the muddy middle. We keep every seed as an anchor
///     and score a candidate on a blend of (a) closeness to the centroid and
///     (b) closeness to its *nearest* anchor — so both poles stay represented.
///  2. **The adventurousness dial.** One knob (0 = familiar, 1 = adventurous)
///     that simultaneously biases toward novelty (unheard artists / farther-out
///     sonics) and loosens the MMR diversity λ, so the station can be a cosy
///     deep-cut hour or a voyage.
///  3. **Taste steering in vector space.** Liked tracks pull the query toward
///     them; disliked tracks push it away (reusing the Song-Alchemy ADD/SUBTRACT
///     idea) — and disliked tracks can be hard-banned instead of down-sampled.
///  4. **MMR diversification + a reason per pick**, so the result isn't five
///     tracks off one album and every track can explain why it's there.
///
/// Pure + deterministic given its inputs (a `salt` seeds the daily variety), runs
/// off-main. Requires a `VectorIndex`; callers keep the rule-based path for when
/// embeddings are absent or the A/B flag is off.
public enum RadioEngine {

    // MARK: Options

    public struct Options: Sendable {
        /// 0 = play it safe (close + familiar), 1 = surprise me (far + new).
        public var adventurousness: Double
        /// How many ranked, diversified tracks to return.
        public var poolLimit: Int
        /// Size of the raw cosine pool considered before MMR (≫ poolLimit).
        public var candidateK: Int
        /// Remove disliked tracks entirely (vs. the caller's soft down-sampling).
        public var hardBanDisliked: Bool
        /// Flow-order the result into a smooth journey (off for "ranked list" UIs).
        public var sequence: Bool
        /// Energy shape when sequencing.
        public var arc: RadioSequencer.Arc

        public init(adventurousness: Double = 0.35, poolLimit: Int = 250, candidateK: Int = 900,
                    hardBanDisliked: Bool = false, sequence: Bool = true,
                    arc: RadioSequencer.Arc = .smooth) {
            self.adventurousness = min(1, max(0, adventurousness))
            self.poolLimit = poolLimit
            self.candidateK = candidateK
            self.hardBanDisliked = hardBanDisliked
            self.sequence = sequence
            self.arc = arc
        }
    }

    // MARK: Reason (explainability — "why is this here?")

    public struct Reason: Sendable, Equatable, Codable {
        public enum Kind: String, Sendable, Codable {
            case similar     // sonically close to a seed
            case favorite    // near something you thumbed up
            case genre       // shares the station's genre
            case discovery   // a deliberate stretch / unheard artist
        }
        public var kind: Kind
        public var detail: String   // e.g. an artist name or genre, may be empty

        /// A short Dutch sentence for the UI ("Waarom deze track").
        public var text: String {
            switch kind {
            case .similar:   return detail.isEmpty ? "Klinkt als je seeds" : "Klinkt als \(detail)"
            case .favorite:  return detail.isEmpty ? "Past bij je likes" : "Omdat je \(detail) mooi vond"
            case .genre:     return detail.isEmpty ? "Past bij het genre" : "Uit je \(detail)-hoek"
            case .discovery: return detail.isEmpty ? "Ontdekking" : "Ontdekking — \(detail)"
            }
        }
    }

    public struct Result: Sendable {
        public var track: DatabaseManager.SonicTrack
        public var score: Double
        public var reason: Reason
    }

    // MARK: Ranking

    /// Rank + diversify the library around `seeds`. `index` is required (the
    /// embedding path); callers fall back to `SonicEngine` when it's nil.
    public static func rank(
        seeds: [DatabaseManager.SonicTrack],
        library: [DatabaseManager.SonicTrack],
        index: VectorIndex,
        options: Options,
        disliked: Set<String> = [],
        likedKeys: Set<String> = [],
        knownArtists: Set<String> = [],
        tasteVector: [Float]? = nil,
        seedGenres: Set<String> = [],
        genresById: [String: Set<String>] = [:],
        salt: String = ""
    ) -> [Result] {
        // Anchors: the seed vectors that exist in the index. Cap for cost.
        let seedIds = seeds.map(\.id)
        var anchors: [[Float]] = []
        anchors.reserveCapacity(min(seedIds.count, maxAnchors))
        for id in seedIds where anchors.count < maxAnchors {
            if let e = index.embedding(forId: id) { anchors.append(e) }
        }
        guard let centroid = index.centroid(ofIds: seedIds) else { return [] }

        // Map content keys → track ids so like/dislike (keyed by matchKey) resolve
        // to the embedding index (keyed by Roon id).
        var idByKey = [String: String](minimumCapacity: index.tracks.count)
        for t in index.tracks where !t.matchKey.isEmpty { idByKey[t.matchKey] = t.id }

        // Query vector = centroid, nudged toward likes + the personal taste
        // vector, and away from dislikes.
        var query = centroid
        if let tv = tasteVector, tv.count == query.count {
            addScaled(&query, tv, tasteVectorBias)
        }
        if !likedKeys.isEmpty {
            let likedIds = likedKeys.compactMap { idByKey[$0] }
            if let likeC = index.centroid(ofIds: likedIds) {
                addScaled(&query, likeC, tasteBias)
            }
        }
        if !disliked.isEmpty {
            let dislikedIds = disliked.compactMap { idByKey[$0] }
            if let disC = index.centroid(ofIds: dislikedIds) {
                addScaled(&query, disC, -dislikePush)
            }
        }
        query = VectorIndex.normalized(query)

        let excluded = Set(seedIds)
        let hits = index.nearest(to: query, k: options.candidateK, excludingIds: excluded)
        guard !hits.isEmpty else { return [] }

        let adv = options.adventurousness

        // Score each candidate: centroid+anchor relevance, plus familiarity /
        // discovery bonuses gated by the dial, plus a tiny daily jitter.
        struct Scored { let track: DatabaseManager.SonicTrack; let emb: [Float]; let score: Double; let nearestAnchor: Int; let anchorSim: Double }
        var scored: [Scored] = []
        scored.reserveCapacity(hits.count)
        for h in hits {
            let mk = h.track.matchKey
            if options.hardBanDisliked, !mk.isEmpty, disliked.contains(mk) { continue }
            guard let emb = index.embedding(forId: h.track.id) else { continue }

            // Nearest anchor (preserve multimodal seed sets).
            var bestAnchorSim = -1.0
            var bestAnchor = -1
            for (ai, a) in anchors.enumerated() {
                let s = dot(emb, a)
                if s > bestAnchorSim { bestAnchorSim = s; bestAnchor = ai }
            }
            let relCentroid = Double(max(0, h.score))
            let relAnchor = anchors.isEmpty ? relCentroid : max(0, bestAnchorSim)
            let relevance = (1 - anchorBlend) * relCentroid + anchorBlend * relAnchor

            let artist = (h.track.artist ?? "").lowercased()
            let isKnown = !artist.isEmpty && knownArtists.contains(artist)
            let distanceNovelty = 1 - relAnchor                 // farther = more novel
            let familiarBonus = (1 - adv) * 0.15 * (isKnown ? 1 : 0)
            let discoveryBonus = adv * (0.18 * (isKnown ? 0 : 1) + 0.12 * distanceNovelty)
            let jitter = salt.isEmpty ? 0
                : Double(RoonClient.seed64("\(salt)\u{1f}\(h.track.id)") % 1000) / 1000.0 * 0.04

            let score = relevance + familiarBonus + discoveryBonus + jitter
            scored.append(Scored(track: h.track, emb: emb, score: score,
                                  nearestAnchor: bestAnchor, anchorSim: relAnchor))
        }
        guard !scored.isEmpty else { return [] }
        scored.sort { $0.score > $1.score }

        // MMR diversification: λ from the dial — adventurous stations tolerate
        // (indeed want) more spread, cosy ones stay tightly on-theme. At the
        // default dial (0.35) this gives λ≈0.82: relevance-led but with enough
        // spread that a playlist isn't five near-identical tracks in a row.
        let lambda = 1 - 0.5 * adv
        let picked = mmr(scored.map { ($0.track, $0.emb, $0.score) },
                         limit: min(options.poolLimit, scored.count), lambda: lambda)

        // Reason per pick.
        let scoredByID = Dictionary(scored.map { ($0.track.id, $0) }, uniquingKeysWith: { a, _ in a })
        let likedSet = likedKeys
        var results: [Result] = []
        results.reserveCapacity(picked.count)
        for t in picked {
            let s = scoredByID[t.id]
            let reason = reasonFor(track: t, likedKeys: likedSet, idByKey: idByKey,
                                   seeds: seeds, seedGenres: seedGenres, genresById: genresById, adv: adv)
            results.append(Result(track: t, score: s?.score ?? 0, reason: reason))
        }

        if options.sequence {
            let ordered = RadioSequencer.order(results.map(\.track),
                                               preferredStartIds: Set(seedIds), arc: options.arc)
            let reasonByID = Dictionary(results.map { ($0.track.id, $0) }, uniquingKeysWith: { a, _ in a })
            return ordered.compactMap { reasonByID[$0.id] }
        }
        return results
    }

    // MARK: - Reason inference

    private static func reasonFor(
        track t: DatabaseManager.SonicTrack, likedKeys: Set<String>, idByKey: [String: String],
        seeds: [DatabaseManager.SonicTrack], seedGenres: Set<String>,
        genresById: [String: Set<String>], adv: Double
    ) -> Reason {
        // The track is itself one the user thumbed up.
        if !t.matchKey.isEmpty, likedKeys.contains(t.matchKey) {
            return Reason(kind: .favorite, detail: t.artist ?? "")
        }
        // Shares the station genre?
        if !seedGenres.isEmpty, let g = genresById[t.id]?.first(where: { seedGenres.contains($0) }) {
            return Reason(kind: .genre, detail: g)
        }
        // Deliberate stretch on an adventurous dial?
        if adv >= 0.6 { return Reason(kind: .discovery, detail: t.artist ?? "") }
        // Default: sounds like the closest seed.
        let nearest = seeds.first?.artist ?? ""
        return Reason(kind: .similar, detail: nearest)
    }

    // MARK: - MMR

    /// Maximal Marginal Relevance: greedily pick the candidate maximising
    /// `λ·relevance − (1−λ)·maxCosineToAlreadyPicked`, killing near-duplicate
    /// clusters. Operates on (track, normalized-embedding, relevance).
    static func mmr(_ items: [(DatabaseManager.SonicTrack, [Float], Double)],
                    limit: Int, lambda: Double) -> [DatabaseManager.SonicTrack] {
        guard !items.isEmpty else { return [] }
        guard items.count > limit else { return items.map { $0.0 } }

        // Normalise relevance to 0…1 so it's comparable to the cosine penalty.
        let rels = items.map { $0.2 }
        let lo = rels.min() ?? 0, hi = rels.max() ?? 1
        let span = max(1e-6, hi - lo)
        let normRel = rels.map { ($0 - lo) / span }

        var remaining = Array(items.indices)
        var pickedIdx: [Int] = []
        // Seed with the most relevant.
        if let first = remaining.max(by: { normRel[$0] < normRel[$1] }) {
            pickedIdx.append(first)
            remaining.removeAll { $0 == first }
        }
        // Track the running max similarity of each remaining item to the picked set.
        var maxSimToPicked = [Double](repeating: -1, count: items.count)
        func refreshAgainst(_ p: Int) {
            for i in remaining {
                let s = Double(dot(items[i].1, items[p].1))
                if s > maxSimToPicked[i] { maxSimToPicked[i] = s }
            }
        }
        if let p = pickedIdx.first { refreshAgainst(p) }

        while pickedIdx.count < limit, !remaining.isEmpty {
            var bestIdx = remaining[0]
            var bestMMR = -Double.infinity
            for i in remaining {
                let mmr = lambda * normRel[i] - (1 - lambda) * max(0, maxSimToPicked[i])
                if mmr > bestMMR { bestMMR = mmr; bestIdx = i }
            }
            pickedIdx.append(bestIdx)
            remaining.removeAll { $0 == bestIdx }
            refreshAgainst(bestIdx)
        }
        return pickedIdx.map { items[$0].0 }
    }

    // MARK: - Tunables + vector helpers

    private static let maxAnchors = 24
    private static let anchorBlend = 0.5     // centroid ↔ nearest-anchor mix
    private static let tasteBias: Float = 0.30        // pull toward liked centroid
    private static let tasteVectorBias: Float = 0.35  // pull toward the recency-weighted taste vector
    private static let dislikePush: Float = 0.40      // push away from disliked centroid

    private static func dot(_ a: [Float], _ b: [Float]) -> Double {
        var d: Float = 0
        vDSP_dotpr(a, 1, b, 1, &d, vDSP_Length(min(a.count, b.count)))
        return Double(d)
    }

    /// query += scale · v (v need not be normalized; query renormalized by caller).
    private static func addScaled(_ query: inout [Float], _ v: [Float], _ scale: Float) {
        let n = min(query.count, v.count)
        var i = 0
        while i < n { query[i] += scale * v[i]; i += 1 }
    }
}
