import Foundation

/// Ranking + aggregation on top of `SonicSimilarity`. Pure functions over
/// `DatabaseManager.SonicTrack` so they're unit-testable and shared by the
/// Sonic Radio, Sonic Fingerprint and Music Map features.
public enum SonicEngine {

    public struct Scored: Sendable, Identifiable {
        public var track: DatabaseManager.SonicTrack
        public var similarity: Double   // 0…1, higher = closer
        /// Why this track is here ("klinkt als…", "ontdekking", …). Set by the
        /// smart `RadioEngine` paths; nil for the rule-based fallback.
        public var reason: RadioEngine.Reason?
        public var id: String { track.id }
        public init(track: DatabaseManager.SonicTrack, similarity: Double, reason: RadioEngine.Reason? = nil) {
            self.track = track; self.similarity = similarity; self.reason = reason
        }
    }

    static func feature(_ t: DatabaseManager.SonicTrack) -> SonicSimilarity.Feature {
        SonicSimilarity.Feature(bpm: t.bpm, camelot: t.camelot, energy: t.energy, tags: t.tags)
    }

    private static func sameTrack(_ a: DatabaseManager.SonicTrack, _ b: DatabaseManager.SonicTrack) -> Bool {
        if a.id == b.id { return true }
        return a.title.lowercased() == b.title.lowercased()
            && (a.artist ?? "").lowercased() == (b.artist ?? "").lowercased()
    }

    /// Library tracks most sonically similar to `seed`, nearest first. The seed
    /// (and other copies of it) are excluded.
    public static func similar(
        to seed: DatabaseManager.SonicTrack,
        in library: [DatabaseManager.SonicTrack],
        limit: Int = 30,
        weights: SonicSimilarity.Weights = .default,
        index: VectorIndex? = nil
    ) -> [Scored] {
        // Embedding path: learned cosine k-NN when the seed has a vector.
        if let index, index.embedding(forId: seed.id) != nil {
            return index.nearest(toId: seed.id, k: limit)
                .map { Scored(track: $0.track, similarity: Double(max(0, $0.score))) }
        }
        let seedPrepared = SonicSimilarity.Prepared(feature(seed))
        let libraryPrepared = library
            .filter { !sameTrack($0, seed) }
            .map { (track: $0, prep: SonicSimilarity.Prepared(feature($0))) }
        return libraryPrepared
            .map { Scored(track: $0.track, similarity: SonicSimilarity.similarity(seedPrepared, $0.prep, weights: weights)) }
            .sorted { $0.similarity > $1.similarity }
            .prefix(limit)
            .map { $0 }
    }

    /// Tracks closest to a set of seeds (mean similarity), nearest first.
    /// Seeds themselves are excluded. Used for Sonic Fingerprint recommendations.
    public static func nearest(
        toSeeds seeds: [DatabaseManager.SonicTrack],
        in library: [DatabaseManager.SonicTrack],
        limit: Int = 50,
        weights: SonicSimilarity.Weights = .default,
        index: VectorIndex? = nil,
        seedWeights: [Float]? = nil
    ) -> [Scored] {
        guard !seeds.isEmpty else { return [] }
        // Embedding path: (recency-weighted) centroid → cosine k-NN.
        if let index {
            let seedIds = seeds.map(\.id).filter { index.embedding(forId: $0) != nil }
            if !seedIds.isEmpty, let centroid = index.centroid(ofIds: seedIds, weights: seedWeights) {
                return index.nearest(to: centroid, k: limit, excludingIds: Set(seedIds))
                    .map { Scored(track: $0.track, similarity: Double(max(0, $0.score))) }
            }
        }
        let seedPreps = seeds.map { SonicSimilarity.Prepared(feature($0)) }
        let seedKeys = Set(seeds.map { "\($0.title.lowercased())|\(($0.artist ?? "").lowercased())" })
        var scored: [Scored] = []
        scored.reserveCapacity(library.count)
        for t in library {
            let key = "\(t.title.lowercased())|\((t.artist ?? "").lowercased())"
            if seedKeys.contains(key) { continue }
            let f = SonicSimilarity.Prepared(feature(t))
            var sum = 0.0
            for sf in seedPreps { sum += SonicSimilarity.similarity(sf, f, weights: weights) }
            scored.append(Scored(track: t, similarity: sum / Double(seedPreps.count)))
        }
        return scored.sorted { $0.similarity > $1.similarity }.prefix(limit).map { $0 }
    }

    // MARK: - Fingerprint profile (for the radar visualization)

    public struct Profile: Sendable {
        /// Radar axes, each normalized 0…1.
        public var energy: Double
        public var tempo: Double          // avg BPM mapped 60→0, 180→1
        public var majorAffinity: Double  // fraction in a major (B) key
        public var tempoVariety: Double   // BPM spread
        public var tagRichness: Double    // avg distinct tags per track
        public var avgBPM: Double
        public var topTags: [(tag: String, count: Int)]
        public var sampleCount: Int
    }

    public static func profile(of tracks: [DatabaseManager.SonicTrack]) -> Profile {
        let bpms = tracks.compactMap { $0.bpm }.filter { $0 > 0 }
        let energies = tracks.compactMap { $0.energy }
        let avgBPM = bpms.isEmpty ? 0 : bpms.reduce(0, +) / Double(bpms.count)
        let avgEnergy = energies.isEmpty ? 0 : energies.reduce(0, +) / Double(energies.count)

        let majorCount = tracks.filter { $0.camelot.hasSuffix("B") }.count
        let keyed = tracks.filter { !$0.camelot.isEmpty }.count
        let majorAffinity = keyed == 0 ? 0.5 : Double(majorCount) / Double(keyed)

        // BPM spread → variety axis (std-dev, normalized by 30 BPM).
        let variety: Double
        if bpms.count > 1 {
            let mean = avgBPM
            let varSum = bpms.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            variety = min(1, (varSum / Double(bpms.count)).squareRoot() / 30.0)
        } else { variety = 0 }

        let avgTags = tracks.isEmpty ? 0 : Double(tracks.reduce(0) { $0 + $1.tags.count }) / Double(tracks.count)
        let tagRichness = min(1, avgTags / 5.0)

        var tagCounts: [String: Int] = [:]
        for t in tracks { for tag in t.tags { tagCounts[tag, default: 0] += 1 } }
        let topTags = tagCounts.sorted { $0.value > $1.value }.prefix(8).map { (tag: $0.key, count: $0.value) }

        return Profile(
            energy: min(1, avgEnergy),
            tempo: min(1, max(0, (avgBPM - 60) / 120)),
            majorAffinity: majorAffinity,
            tempoVariety: variety,
            tagRichness: tagRichness,
            avgBPM: avgBPM,
            topTags: topTags,
            sampleCount: tracks.count
        )
    }

    // MARK: - Song Alchemy

    /// Vector mixing: find tracks matching mean(add) − 0.5 × mean(subtract).
    /// Centroid is a weighted average of the feature components; Jaccard tags
    /// are merged proportionally.
    public static func alchemy(
        add: [DatabaseManager.SonicTrack],
        subtract: [DatabaseManager.SonicTrack],
        in library: [DatabaseManager.SonicTrack],
        limit: Int = 30,
        weights: SonicSimilarity.Weights = .default,
        index: VectorIndex? = nil
    ) -> [Scored] {
        guard !add.isEmpty else { return [] }

        // Embedding path: combined = mean(add) − 0.5·mean(subtract) in vector space.
        if let index, add.contains(where: { index.embedding(forId: $0.id) != nil }),
           let addC = index.centroid(ofIds: add.map(\.id)) {
            var combined = addC
            if !subtract.isEmpty, let subC = index.centroid(ofIds: subtract.map(\.id)) {
                for i in 0..<min(combined.count, subC.count) { combined[i] -= 0.5 * subC[i] }
            }
            let exclude = Set(add.map(\.id) + subtract.map(\.id))
            return index.nearest(to: combined, k: limit, excludingIds: exclude)
                .map { Scored(track: $0.track, similarity: Double(max(0, $0.score))) }
        }

        func avg<T: BinaryFloatingPoint>(_ vals: [T?]) -> T? {
            let v = vals.compactMap { $0 }
            return v.isEmpty ? nil : v.reduce(0, +) / T(v.count)
        }

        // Add centroid
        let addBPM    = avg(add.map { $0.bpm })
        let addEnergy = avg(add.map { $0.energy })
        let addCamelot = add.first(where: { !$0.camelot.isEmpty })?.camelot ?? ""
        var addTagCounts: [String: Int] = [:]
        for t in add { for tag in t.tags { addTagCounts[tag, default: 0] += 1 } }
        let addTags = addTagCounts.filter { $0.value >= max(1, add.count / 2) }.map { $0.key }

        // Subtract influence (dampen BPM/energy; for tags: remove overlapping ones)
        let subBPM    = avg(subtract.map { $0.bpm })
        let subEnergy = avg(subtract.map { $0.energy })
        var subTagSet = Set<String>()
        for t in subtract { for tag in t.tags { subTagSet.insert(tag) } }

        let mixBPM: Double?
        if let a = addBPM, let s = subBPM {
            mixBPM = max(40, min(200, a - 0.5 * (s - a)))   // push away from subtract direction
        } else { mixBPM = addBPM }

        let mixEnergy: Double?
        if let a = addEnergy, let s = subEnergy {
            mixEnergy = max(0, min(1, a - 0.5 * (s - a)))
        } else { mixEnergy = addEnergy }

        let mixTags = addTags.filter { !subTagSet.contains($0) }

        let mixFeature = SonicSimilarity.Feature(
            bpm: mixBPM, camelot: addCamelot, energy: mixEnergy, tags: mixTags)
        let mixPrep = SonicSimilarity.Prepared(mixFeature)

        let excludeIDs = Set(add.map(\.id) + subtract.map(\.id))
        var scored: [Scored] = []
        for t in library {
            if excludeIDs.contains(t.id) { continue }
            let prep = SonicSimilarity.Prepared(SonicSimilarity.Feature(
                bpm: t.bpm, camelot: t.camelot, energy: t.energy, tags: t.tags))
            scored.append(Scored(track: t, similarity: SonicSimilarity.similarity(mixPrep, prep, weights: weights)))
        }
        return scored.sorted { $0.similarity > $1.similarity }.prefix(limit).map { $0 }
    }
}
