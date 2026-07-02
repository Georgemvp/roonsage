@testable import RoonSageCore
import XCTest

/// Sonic DNA engine — weighted seeds, profile axes, evolution and taste cores.
final class SonicDNATests: XCTestCase {

    private func track(
        _ id: String, artist: String = "A", bpm: Double = 120, energy: Double? = 0.5,
        tags: [String] = [], emb: [Float]? = nil, attributes: [String: Float] = [:],
        moods: [String: Float] = [:], popularity: Int? = nil
    ) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(
            id: id, title: id, artist: artist, album: "Al", imageKey: nil, matchKey: id,
            bpm: bpm, camelot: "8B", energy: energy, tags: tags, embedding: emb,
            moods: moods, attributes: attributes, popularity: popularity)
    }

    private func iso(daysAgo: Double, now: Date) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-daysAgo * 86_400))
    }

    // MARK: - Weights + seed selection

    func testPlayWeightFavoursRecentAndFrequent() {
        let now = Date()
        let recentHeavy = SonicDNA.playWeight(count: 50, lastPlayed: iso(daysAgo: 1, now: now), now: now)
        let oldHeavy = SonicDNA.playWeight(count: 50, lastPlayed: iso(daysAgo: 600, now: now), now: now)
        let recentLight = SonicDNA.playWeight(count: 2, lastPlayed: iso(daysAgo: 1, now: now), now: now)
        XCTAssertGreaterThan(recentHeavy, oldHeavy, "recency decays weight")
        XCTAssertGreaterThan(recentHeavy, recentLight, "plays raise weight")
        XCTAssertGreaterThan(oldHeavy, 0, "old favourites still register")
    }

    func testSelectSeedsExcludesDislikedAndAddsLiked() {
        let now = Date()
        let a = track("a"), b = track("b"), c = track("c")
        let byKey = ["a": a, "b": b, "c": c]
        let stats = [
            SonicDNA.PlayStat(matchKey: "a", count: 100, lastPlayed: iso(daysAgo: 1, now: now)),
            SonicDNA.PlayStat(matchKey: "b", count: 90, lastPlayed: iso(daysAgo: 1, now: now)),
        ]
        let seeds = SonicDNA.selectSeeds(
            playStats: stats, byMatchKey: byKey,
            liked: ["c"], disliked: ["b"], limit: 10, now: now)
        let ids = seeds.map { $0.track.id }
        XCTAssertTrue(ids.contains("a"))
        XCTAssertTrue(ids.contains("c"), "liked-but-unplayed joins the seed set")
        XCTAssertFalse(ids.contains("b"), "disliked never defines the DNA")
        XCTAssertEqual(ids.first, "a", "heaviest seed first")
    }

    func testSelectSeedsWeightsRecencyOverAllTimeCount() {
        let now = Date()
        let old = track("old"), fresh = track("fresh")
        let stats = [
            SonicDNA.PlayStat(matchKey: "old", count: 500, lastPlayed: iso(daysAgo: 900, now: now)),
            SonicDNA.PlayStat(matchKey: "fresh", count: 40, lastPlayed: iso(daysAgo: 2, now: now)),
        ]
        let seeds = SonicDNA.selectSeeds(
            playStats: stats, byMatchKey: ["old": old, "fresh": fresh],
            liked: [], disliked: [], limit: 10, now: now)
        XCTAssertEqual(seeds.first?.track.id, "fresh",
                       "recent listening outweighs a stale all-time count")
    }

    func testLibrarySampleSeedsIsStridedAndDeterministic() {
        let lib = (0..<100).map { track("t\($0)") }
        let s1 = SonicDNA.librarySampleSeeds(lib, limit: 10)
        let s2 = SonicDNA.librarySampleSeeds(lib, limit: 10)
        XCTAssertEqual(s1.map { $0.track.id }, s2.map { $0.track.id })
        XCTAssertEqual(s1.count, 10)
        XCTAssertNotEqual(s1.map { $0.track.id }, (0..<10).map { "t\($0)" },
                          "a strided sample, not the first N rows")
    }

    // MARK: - Profile

    func testProfileWeightsSeedsByPlayWeight() {
        // Heavy seed is high-energy; light seed is low-energy.
        let heavy = SonicDNA.Seed(track: track("h", energy: 1.0), weight: 9)
        let light = SonicDNA.Seed(track: track("l", energy: 0.0), weight: 1)
        let p = SonicDNA.profile(seeds: [heavy, light], index: nil, genresById: [:], library: [])
        XCTAssertEqual(p.energy, 0.9, accuracy: 0.001, "weighted, not plain, mean")
    }

    func testProfileAttributesAndNeutralFallback() {
        let s = SonicDNA.Seed(track: track("a", attributes: ["danceability": 0.8, "valence": 0.2]), weight: 1)
        let p = SonicDNA.profile(seeds: [s], index: nil, genresById: [:], library: [])
        XCTAssertEqual(p.danceability, 0.8, accuracy: 0.001)
        XCTAssertEqual(p.valence, 0.2, accuracy: 0.001)
        XCTAssertEqual(p.acousticness, 0.5, accuracy: 0.001, "missing axis sits neutral")
    }

    func testProfileGenreDNADropsUmbrellaGenres() {
        // "pop/rock" tags 60% of the library → umbrella → dropped from the DNA;
        // Krautrock covers only 20% → discriminating → kept.
        var genres: [String: Set<String>] = [:]
        for i in 0..<10 {
            genres["t\(i)"] = i < 6 ? ["Pop/Rock"] : (i < 8 ? ["Krautrock"] : ["Ambient"])
        }
        let seeds = [
            SonicDNA.Seed(track: track("t0"), weight: 5),   // Pop/Rock
            SonicDNA.Seed(track: track("t7"), weight: 3),   // Krautrock
        ]
        let p = SonicDNA.profile(seeds: seeds, index: nil, genresById: genres, library: [])
        XCTAssertEqual(p.topGenres.map { $0.name }, ["Krautrock"])
    }

    func testProfileMainstreamRelativeToLibrary() {
        let lib = [track("lo", popularity: 100), track("hi", popularity: 900_000)]
        let hit = SonicDNA.Seed(track: track("hi", popularity: 900_000), weight: 1)
        let deep = SonicDNA.Seed(track: track("lo", popularity: 100), weight: 1)
        let pHit = SonicDNA.profile(seeds: [hit], index: nil, genresById: [:], library: lib)
        let pDeep = SonicDNA.profile(seeds: [deep], index: nil, genresById: [:], library: lib)
        XCTAssertGreaterThan(pHit.mainstream, 0.9)
        XCTAssertLessThan(pDeep.mainstream, 0.1)
    }

    func testAdventureUsesArtistDiversity() {
        let same = (0..<10).map { SonicDNA.Seed(track: track("s\($0)", artist: "One"), weight: 1) }
        let varied = (0..<10).map { SonicDNA.Seed(track: track("v\($0)", artist: "A\($0)"), weight: 1) }
        let pSame = SonicDNA.profile(seeds: same, index: nil, genresById: [:], library: [])
        let pVaried = SonicDNA.profile(seeds: varied, index: nil, genresById: [:], library: [])
        XCTAssertGreaterThan(pVaried.adventure, pSame.adventure)
    }

    // MARK: - Evolution

    func testEvolutionReportsBiggestMoversAboveThreshold() {
        var recent = SonicDNA.profile(seeds: [SonicDNA.Seed(track: track("a", energy: 1.0), weight: 1)],
                                      index: nil, genresById: [:], library: [])
        var allTime = SonicDNA.profile(seeds: [SonicDNA.Seed(track: track("a", energy: 0.5), weight: 1)],
                                       index: nil, genresById: [:], library: [])
        recent.danceability = 0.52; allTime.danceability = 0.50   // below threshold
        let deltas = SonicDNA.evolution(recent: recent, allTime: allTime)
        XCTAssertEqual(deltas.first?.label, "Energie")
        XCTAssertEqual(deltas.first?.delta ?? 0, 0.5, accuracy: 0.001)
        XCTAssertFalse(deltas.contains { $0.label == "Dansbaar" }, "small wiggle ignored")
    }

    // MARK: - Cores

    /// Two obvious sonic pockets → two (or more) cores, split along them, with
    /// the heavier pocket first and stable across runs.
    func testCoresFindWeightedPocketsDeterministically() throws {
        var seeds: [SonicDNA.Seed] = []
        var tracks: [DatabaseManager.SonicTrack] = []
        for i in 0..<10 {
            let t = track("amb\(i)", artist: "Amb\(i)", emb: [1, 0, 0.01 * Float(i), 0])
            tracks.append(t)
            seeds.append(SonicDNA.Seed(track: t, weight: 10))     // heavy pocket
        }
        for i in 0..<8 {
            let t = track("hse\(i)", artist: "Hse\(i)", emb: [0, 1, 0, 0.01 * Float(i)])
            tracks.append(t)
            seeds.append(SonicDNA.Seed(track: t, weight: 1))      // light pocket
        }
        let index = try XCTUnwrap(VectorIndex(tracks: tracks))
        let cores = SonicDNA.cores(seeds: seeds, index: index, genresById: [:])
        XCTAssertGreaterThanOrEqual(cores.count, 2)
        XCTAssertTrue(cores[0].trackIds.allSatisfy { $0.hasPrefix("amb") },
                      "heaviest core = the heavy pocket")
        // The heavy ambient pocket may split across two cores, but the light
        // house pocket always ranks below any ambient core.
        let houseCore = try XCTUnwrap(cores.first { $0.trackIds.contains { $0.hasPrefix("hse") } })
        XCTAssertGreaterThan(cores[0].share, houseCore.share)
        let again = SonicDNA.cores(seeds: seeds, index: index, genresById: [:])
        XCTAssertEqual(cores.map { $0.id }, again.map { $0.id }, "deterministic")
    }

    /// The screenshot bug: three cores in a Pop/Rock-dominated library all
    /// labelled "Pop/Rock". The umbrella genre must be dropped and sibling cores
    /// must get distinct labels (from moods/tags/artists).
    func testCoresDoNotAllShareTheUmbrellaGenre() throws {
        var seeds: [SonicDNA.Seed] = []
        var tracks: [DatabaseManager.SonicTrack] = []
        var genres: [String: Set<String>] = [:]
        // Pocket A: mellow (embeds ~[1,0]), tagged Pop/Rock + "akoestisch".
        for i in 0..<12 {
            let t = track("a\(i)", artist: "AA\(i)", tags: ["akoestisch"],
                          emb: [1, 0, 0.01 * Float(i), 0], moods: ["relaxed": 0.6])
            tracks.append(t); genres["a\(i)"] = ["Pop/Rock"]
            seeds.append(SonicDNA.Seed(track: t, weight: 5))
        }
        // Pocket B: punchy (embeds ~[0,1]), same umbrella genre, different mood/tag.
        for i in 0..<12 {
            let t = track("b\(i)", artist: "BB\(i)", tags: ["stevig"],
                          emb: [0, 1, 0, 0.01 * Float(i)], moods: ["aggressive": 0.6])
            tracks.append(t); genres["b\(i)"] = ["Pop/Rock"]
            seeds.append(SonicDNA.Seed(track: t, weight: 1))
        }
        let index = try XCTUnwrap(VectorIndex(tracks: tracks))
        let cores = SonicDNA.cores(seeds: seeds, index: index, genresById: genres)
        XCTAssertGreaterThanOrEqual(cores.count, 2)
        let labels = cores.map { $0.label }
        XCTAssertEqual(Set(labels).count, labels.count, "labels must be unique, not 3× Pop/Rock")
        XCTAssertFalse(labels.contains("Pop/Rock"), "umbrella genre dropped from labels")
    }

    func testCoresRequireEnoughEmbeddedSeeds() throws {
        let tracks = (0..<6).map { track("t\($0)", emb: [Float($0), 1, 0, 0]) }
        let index = try XCTUnwrap(VectorIndex(tracks: tracks))
        let seeds = tracks.map { SonicDNA.Seed(track: $0, weight: 1) }
        XCTAssertTrue(SonicDNA.cores(seeds: seeds, index: index, genresById: [:]).isEmpty,
                      "fewer than 12 embedded seeds → no cores")
    }

    // MARK: - Weighted centroid + dedup/cap plumbing

    func testWeightedCentroidLeansTowardHeavyVector() {
        let c = VectorIndex.weightedCentroid([([1, 0], 9), ([0, 1], 1)])
        XCTAssertNotNil(c)
        XCTAssertGreaterThan(c![0], c![1])
    }

    func testDedupAndCapCollapsesContentAndCapsArtists() {
        func scored(_ id: String, _ mk: String, _ artist: String) -> SonicEngine.Scored {
            SonicEngine.Scored(
                track: DatabaseManager.SonicTrack(
                    id: id, title: id, artist: artist, album: nil, imageKey: nil, matchKey: mk,
                    bpm: 120, camelot: "8B", energy: 0.5, tags: []),
                similarity: 0.9)
        }
        let list = [
            scored("1", "song-a", "X"), scored("2", "song-a", "X"),   // same content
            scored("3", "song-b", "X"), scored("4", "song-c", "X"),   // 3rd X track
            scored("5", "seed", "Y"),                                  // excluded (seed)
            scored("6", "song-d", "Z"),
        ]
        let out = RoonClient.dedupAndCap(list, excludingKeys: ["seed"], maxPerArtist: 2, limit: 10)
        XCTAssertEqual(out.map { $0.track.id }, ["1", "3", "6"])
    }
}
