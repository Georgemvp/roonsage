import Foundation

/// Ranking + aggregation on top of `SonicSimilarity`. Pure functions over
/// `DatabaseManager.SonicTrack` so they're unit-testable and shared by the
/// Sonic Radio, Sonic Fingerprint and Music Map features.
public enum SonicEngine {

    public struct Scored: Sendable, Identifiable {
        public var track: DatabaseManager.SonicTrack
        public var similarity: Double   // 0…1, higher = closer
        public var id: String { track.id }
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
        weights: SonicSimilarity.Weights = .default
    ) -> [Scored] {
        let seedFeature = feature(seed)
        return library
            .filter { !sameTrack($0, seed) }
            .map { Scored(track: $0, similarity: SonicSimilarity.similarity(seedFeature, feature($0), weights: weights)) }
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
        weights: SonicSimilarity.Weights = .default
    ) -> [Scored] {
        guard !seeds.isEmpty else { return [] }
        let seedFeatures = seeds.map(feature)
        let seedKeys = Set(seeds.map { "\($0.title.lowercased())|\(($0.artist ?? "").lowercased())" })
        var scored: [Scored] = []
        scored.reserveCapacity(library.count)
        for t in library {
            let key = "\(t.title.lowercased())|\((t.artist ?? "").lowercased())"
            if seedKeys.contains(key) { continue }
            let f = feature(t)
            var sum = 0.0
            for sf in seedFeatures { sum += SonicSimilarity.similarity(sf, f, weights: weights) }
            scored.append(Scored(track: t, similarity: sum / Double(seedFeatures.count)))
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
}
