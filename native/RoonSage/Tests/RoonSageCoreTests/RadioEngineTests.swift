@testable import RoonSageCore
import XCTest

/// The smart radio ranker: multi-anchor relevance, the adventurousness dial,
/// MMR diversification, hard-ban, and flow sequencing. Pure + deterministic.
final class RadioEngineTests: XCTestCase {

    private func track(_ id: String, _ emb: [Float], artist: String,
                       camelot: String = "8B", bpm: Double = 120, energy: Double = 0.5
    ) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(
            id: id, title: id, artist: artist, album: "Al", imageKey: nil, matchKey: id,
            bpm: bpm, camelot: camelot, energy: energy, tags: [], embedding: emb)
    }

    /// seed at [1,0,0,0]; `near` (cos≈.92, known artist), `mid` (cos≈.7, known),
    /// `far` (cos≈.5, NEW artist).
    private func fixture() -> (seed: DatabaseManager.SonicTrack, lib: [DatabaseManager.SonicTrack], index: VectorIndex) {
        let seed = track("seed", [1, 0, 0, 0], artist: "Seed")
        let near = track("near", [0.92, 0.39, 0, 0], artist: "Known")
        let mid  = track("mid",  [0.70, 0, 0, 0.714], artist: "Known2")
        let far  = track("far",  [0.50, 0, 0.866, 0], artist: "Newbie")
        let lib = [seed, near, mid, far]
        return (seed, lib, VectorIndex(tracks: lib)!)
    }

    func testRankExcludesSeedsAndIsDeterministic() {
        let (seed, lib, index) = fixture()
        let opts = RadioEngine.Options(adventurousness: 0.35, poolLimit: 10, sequence: false)
        let a = RadioEngine.rank(seeds: [seed], library: lib, index: index, options: opts, salt: "day")
        let b = RadioEngine.rank(seeds: [seed], library: lib, index: index, options: opts, salt: "day")
        XCTAssertEqual(a.map { $0.track.id }, b.map { $0.track.id }, "deterministic per salt")
        XCTAssertFalse(a.contains { $0.track.id == "seed" }, "seed excluded from its own station")
        XCTAssertFalse(a.isEmpty)
    }

    func testAdventurousnessLiftsNovelTracks() {
        let (seed, lib, index) = fixture()
        let known: Set<String> = ["known", "known2"]
        // poolLimit == candidate count → pure relevance order (no MMR reshuffle),
        // salt "" → no jitter, so the dial's effect is isolated.
        func rankFar(adv: Double) -> Int {
            let opts = RadioEngine.Options(adventurousness: adv, poolLimit: 3, sequence: false)
            let r = RadioEngine.rank(seeds: [seed], library: lib, index: index, options: opts,
                                     knownArtists: known, salt: "")
            return r.firstIndex { $0.track.id == "far" } ?? .max
        }
        let familiar = rankFar(adv: 0)      // play-it-safe: far (new + distant) sinks
        let adventurous = rankFar(adv: 1)   // surprise-me: far rises
        XCTAssertLessThan(adventurous, familiar,
                          "cranking adventurousness moves the novel, farther-out track up the order")
    }

    func testHardBanRemovesDisliked() {
        let (seed, lib, index) = fixture()
        let opts = RadioEngine.Options(adventurousness: 0.5, poolLimit: 10, hardBanDisliked: true, sequence: false)
        let r = RadioEngine.rank(seeds: [seed], library: lib, index: index, options: opts,
                                 disliked: ["far"], salt: "day")
        XCTAssertFalse(r.contains { $0.track.id == "far" }, "hard-banned track is gone entirely")
    }

    func testQueryAnchorRanksWithoutSeeds() {
        let (_, lib, index) = fixture()
        let opts = RadioEngine.Options(adventurousness: 0.35, poolLimit: 10, sequence: false)
        // No track seeds: the request embedding alone carries the query (Generate).
        let r = RadioEngine.rank(seeds: [], library: lib, index: index, options: opts,
                                 salt: "", queryAnchor: [1, 0, 0, 0])
        XCTAssertEqual(r.first?.track.id, "seed", "cosine-nearest to the anchor leads")
        XCTAssertEqual(r.count, lib.count, "no seeds → nothing excluded")
    }

    func testQueryAnchorBlendsWithSeeds() {
        let (seed, lib, index) = fixture()
        let opts = RadioEngine.Options(adventurousness: 0, poolLimit: 3, sequence: false)
        // Anchor on `far`'s vector: with the 50/50 query blend, far must outrank
        // mid even at a fully familiar dial (so distance-novelty can't be the cause).
        let r = RadioEngine.rank(seeds: [seed], library: lib, index: index, options: opts,
                                 salt: "", queryAnchor: [0.50, 0, 0.866, 0])
        let farIdx = r.firstIndex { $0.track.id == "far" } ?? .max
        let midIdx = r.firstIndex { $0.track.id == "mid" } ?? .max
        XCTAssertLessThan(farIdx, midIdx, "request anchor pulls the query toward its own region")
    }

    func testSkippedTracksSteerTheQueryAwaySymmetrically() {
        // seed at +x; two candidates equidistant from the seed, one toward +y and
        // one toward −y. Skipping a pure +y track must push the query −y (so −y
        // wins), and skipping a pure −y track must push it +x→+y (so +y wins).
        // The symmetry proves the skip push works regardless of tie-breaking.
        let seed = track("seed", [1, 0, 0, 0], artist: "S")
        let plusY  = track("plusY",  [0.8, 0.6, 0, 0], artist: "A")
        let minusY = track("minusY", [0.8, -0.6, 0, 0], artist: "B")
        let skipPlus  = track("skipPlus",  [0, 1, 0, 0], artist: "C")
        let skipMinus = track("skipMinus", [0, -1, 0, 0], artist: "E")
        let lib = [seed, plusY, minusY, skipPlus, skipMinus]
        let index = VectorIndex(tracks: lib)!
        // adv 0 + salt "" + poolLimit ≥ count → pure, jitter-free relevance order.
        let opts = RadioEngine.Options(adventurousness: 0, poolLimit: 10, sequence: false)
        func order(skip: Set<String>) -> [String] {
            RadioEngine.rank(seeds: [seed], library: lib, index: index, options: opts,
                             skippedKeys: skip, salt: "").map { $0.track.id }
        }
        let awayFromPlus = order(skip: ["skipPlus"])
        XCTAssertLessThan(awayFromPlus.firstIndex(of: "minusY")!, awayFromPlus.firstIndex(of: "plusY")!,
                          "skipping a +y track steers the station toward −y")
        let awayFromMinus = order(skip: ["skipMinus"])
        XCTAssertLessThan(awayFromMinus.firstIndex(of: "plusY")!, awayFromMinus.firstIndex(of: "minusY")!,
                          "skipping a −y track steers the station toward +y")
    }

    func testRelatedArtistBonusLiftsFanGraphNeighbour() {
        // `mid` and a twin at the same distance: only the fan-graph membership
        // differs, so the related artist must outrank the unrelated one.
        let seed = track("seed", [1, 0, 0, 0], artist: "Seed")
        let a = track("a", [0.70, 0.714, 0, 0], artist: "FanGraph")
        let b = track("b", [0.70, 0, 0.714, 0], artist: "Stranger")
        let lib = [seed, a, b]
        let index = VectorIndex(tracks: lib)!
        let opts = RadioEngine.Options(adventurousness: 0.35, poolLimit: 2, sequence: false)
        let r = RadioEngine.rank(seeds: [seed], library: lib, index: index, options: opts,
                                 relatedArtists: ["fangraph": 1.0], salt: "")
        XCTAssertEqual(r.first?.track.id, "a",
                       "the Deezer-related artist wins the equidistant tie: \(r.map { $0.track.id })")
    }

    func testRelatedArtistBonusScalesWithWeight() {
        // Two equidistant related artists; the higher-weighted one ranks first.
        let seed = track("seed", [1, 0, 0, 0], artist: "Seed")
        let a = track("a", [0.70, 0.714, 0, 0], artist: "TopRelated")
        let b = track("b", [0.70, 0, 0.714, 0], artist: "TailRelated")
        let lib = [seed, a, b]
        let index = VectorIndex(tracks: lib)!
        let opts = RadioEngine.Options(adventurousness: 0.35, poolLimit: 2, sequence: false)
        let r = RadioEngine.rank(seeds: [seed], library: lib, index: index, options: opts,
                                 relatedArtists: ["toprelated": 1.0, "tailrelated": 0.4], salt: "")
        XCTAssertEqual(r.first?.track.id, "a",
                       "the higher-weighted fan-graph artist ranks first: \(r.map { $0.track.id })")
    }

    func testMMRDiversifiesAwayFromNearDuplicates() {
        // Two near-identical clusters; MMR should not return both cluster members
        // before reaching across to the other cluster.
        func t(_ id: String, _ e: [Float]) -> (DatabaseManager.SonicTrack, [Float], Double) {
            (DatabaseManager.SonicTrack(id: id, title: id, artist: id, album: nil, imageKey: nil,
                                        matchKey: id, bpm: 120, camelot: "8B", energy: 0.5, tags: [],
                                        embedding: e), VectorIndex.normalized(e), 0)
        }
        // relevance descending: a1, a2 (almost identical), then b1.
        let items = [
            (t("a1", [1, 0, 0]).0, VectorIndex.normalized([1, 0, 0]), 1.0),
            (t("a2", [0.99, 0.14, 0]).0, VectorIndex.normalized([0.99, 0.14, 0]), 0.95),
            (t("b1", [0, 1, 0]).0, VectorIndex.normalized([0, 1, 0]), 0.6),
        ]
        // Strong diversity preference (low λ): the 2nd pick should be the distant b1.
        let picked = RadioEngine.mmr(items, limit: 2, lambda: 0.3)
        XCTAssertEqual(picked.first?.id, "a1", "most relevant first")
        XCTAssertEqual(picked.last?.id, "b1", "diversity beats the near-duplicate a2")
    }
}

/// Flow sequencing: smooth ordering that keeps the full set and honours a
/// preferred opener.
final class RadioSequencerTests: XCTestCase {

    private func track(_ id: String, _ emb: [Float], energy: Double) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(id: id, title: id, artist: id, album: nil, imageKey: nil,
                                   matchKey: id, bpm: 120, camelot: "8B", energy: energy, tags: [],
                                   embedding: emb)
    }

    func testOrderKeepsEverythingAndIsDeterministic() {
        let lib = [track("a", [1, 0, 0, 0], energy: 0.3),
                   track("b", [0.9, 0.1, 0, 0], energy: 0.4),
                   track("c", [0, 1, 0, 0], energy: 0.8),
                   track("d", [0, 0, 1, 0], energy: 0.6)]
        let a = RadioSequencer.order(lib)
        let b = RadioSequencer.order(lib)
        XCTAssertEqual(Set(a.map(\.id)), Set(lib.map(\.id)), "no track is dropped or added")
        XCTAssertEqual(a.map(\.id), b.map(\.id), "deterministic")
    }

    func testTiesResolveByIndexNotHashOrder() {
        // No embeddings + identical bpm/camelot/energy → every transition cost ties.
        // The walk must break ties by input index (a sorted scan), not by the
        // per-process-randomized Set iteration order, so the result is stable across
        // launches. With lowest-index-wins and an all-tied set that's the input order.
        func t(_ id: String) -> DatabaseManager.SonicTrack {
            DatabaseManager.SonicTrack(id: id, title: id, artist: id, album: nil, imageKey: nil,
                                       matchKey: id, bpm: 120, camelot: "8A", energy: 0.5, tags: [])
        }
        let lib = (0..<8).map { t("t\($0)") }
        XCTAssertEqual(RadioSequencer.order(lib).map(\.id), lib.map(\.id),
                       "all-tied input keeps input order via the deterministic index tie-break")
    }

    func testPreferredStartOpensThere() {
        let lib = [track("a", [1, 0, 0, 0], energy: 0.3),
                   track("b", [0, 1, 0, 0], energy: 0.9),
                   track("c", [0, 0, 1, 0], energy: 0.5)]
        let out = RadioSequencer.order(lib, preferredStartIds: ["b"])
        XCTAssertEqual(out.first?.id, "b", "opens on the preferred (highest-energy) seed track")
    }
}

/// Sonic neighborhoods: k-means over the embeddings discovers coherent rooms,
/// deterministically.
final class SonicClustersTests: XCTestCase {

    private func t(_ id: String, _ e: [Float]) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(id: id, title: id, artist: id, album: nil, imageKey: nil,
                                   matchKey: id, bpm: 120, camelot: "8A", energy: 0.5, tags: [], embedding: e)
    }

    private func twoGroupLib() -> [DatabaseManager.SonicTrack] {
        var lib: [DatabaseManager.SonicTrack] = []
        for i in 0..<12 { lib.append(t("a\(i)", [1, Float(i) * 0.01, 0, 0])) }   // group near +x
        for i in 0..<12 { lib.append(t("b\(i)", [0, 1, Float(i) * 0.01, 0])) }   // group near +y
        return lib
    }

    func testTwoGroupsNeverShareANeighborhood() {
        let lib = twoGroupLib()
        let clusters = SonicClusters.compute(tracks: lib, index: VectorIndex(tracks: lib)!, genresById: [:])
        XCTAssertGreaterThanOrEqual(clusters.count, 2)
        let clusterOf = Dictionary(uniqueKeysWithValues: clusters.flatMap { c in c.memberIds.map { ($0, c.id) } })
        let aClusters = Set((0..<12).compactMap { clusterOf["a\($0)"] })
        let bClusters = Set((0..<12).compactMap { clusterOf["b\($0)"] })
        XCTAssertTrue(aClusters.isDisjoint(with: bClusters),
                      "sonically-distant groups land in different neighborhoods")
    }

    func testClusteringIsDeterministic() {
        let lib = twoGroupLib()
        let a = SonicClusters.compute(tracks: lib, index: VectorIndex(tracks: lib)!, genresById: [:])
        let b = SonicClusters.compute(tracks: lib, index: VectorIndex(tracks: lib)!, genresById: [:])
        XCTAssertEqual(a.map { $0.memberIds }, b.map { $0.memberIds }, "same library → same neighborhoods")
    }

    /// Regression: a homogeneous library (fewer distinct directions than k) used to
    /// crash with an index-out-of-range. Must return cleanly instead.
    func testIdenticalEmbeddingsDoNotCrash() {
        let lib = (0..<20).map { t("same\($0)", [1, 0, 0, 0]) }   // 20 identical directions
        let clusters = SonicClusters.compute(tracks: lib, index: VectorIndex(tracks: lib)!, genresById: [:])
        XCTAssertTrue(clusters.isEmpty, "one direction → fewer than 2 seeds → no neighborhoods, no crash")
    }

    func testFewDistinctDirectionsDoNotCrash() {
        // 18 tracks spanning only 3 orthogonal directions (< the k floor of 6).
        var lib: [DatabaseManager.SonicTrack] = []
        let dirs: [[Float]] = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]
        for i in 0..<18 { lib.append(t("d\(i)", dirs[i % 3])) }
        let clusters = SonicClusters.compute(tracks: lib, index: VectorIndex(tracks: lib)!, genresById: [:])
        XCTAssertLessThanOrEqual(clusters.count, 3, "clusters never exceed the distinct directions")
        XCTAssertFalse(clusters.isEmpty, "still produces neighborhoods without crashing")
    }

    // MARK: Gap A (AudioMuse-audit) — k-sweep + composietscore

    /// De composietscore moet een schone partitie (geometrie + moods coherent)
    /// verkiezen boven een gemengde partitie van dezelfde punten.
    func testScorePrefersCleanPartition() {
        let dim = 8
        var vecs: [[Float]] = []
        for g in 0..<2 {
            for i in 0..<6 {
                var v = [Float](repeating: 0, count: dim)
                v[g] = 1
                v[2 + ((g * 6 + i) % (dim - 2))] = 0.1   // deterministische jitter
                vecs.append(VectorIndex.normalized(v))
            }
        }
        let moods: [String?] = (0..<12).map { $0 < 6 ? "happy" : "sad" }
        let correct = (0..<12).map { $0 < 6 ? 0 : 1 }
        let mixed = (0..<12).map { $0 % 2 }

        func centroid(_ rows: [Int]) -> [Float] {
            var s = [Float](repeating: 0, count: dim)
            for r in rows { for d in 0..<dim { s[d] += vecs[r][d] } }
            return VectorIndex.normalized(s)
        }
        let cCorrect = [centroid(Array(0..<6)), centroid(Array(6..<12))]
        let cMixed = [centroid((0..<12).filter { $0 % 2 == 0 }),
                      centroid((0..<12).filter { $0 % 2 == 1 })]

        let sCorrect = SonicClusters.clusteringScore(
            vecs: vecs, dominantMoods: moods, assign: correct, centroids: cCorrect)
        let sMixed = SonicClusters.clusteringScore(
            vecs: vecs, dominantMoods: moods, assign: mixed, centroids: cMixed)
        XCTAssertGreaterThan(sCorrect, sMixed, "schone partitie moet hoger scoren")
    }

    /// Sweep-gedrag op drie orthogonale mood-coherente groepen: over-splitsen
    /// mag (kandidaten starten op k=6), maar een buurt mengt nooit twee
    /// richtingen en elk punt blijft toegewezen.
    func testSweepNeverMixesDirections() {
        let moods = ["happy", "sad", "relaxed"]
        var lib: [DatabaseManager.SonicTrack] = []
        for g in 0..<3 {
            for i in 0..<12 {
                var v = [Float](repeating: 0, count: 16)
                v[g] = 1
                v[3 + ((g * 12 + i) % 13)] = 0.15   // deterministische jitter
                var track = t("g\(g)-\(i)", v)
                track.moods = [moods[g]: 0.8]
                lib.append(track)
            }
        }
        let clusters = SonicClusters.compute(tracks: lib, index: VectorIndex(tracks: lib)!, genresById: [:])
        XCTAssertGreaterThanOrEqual(clusters.count, 2)
        for c in clusters {
            let groups = Set(c.memberIds.map { $0.prefix(2) })
            XCTAssertEqual(groups.count, 1, "buurt mengt richtingen: \(c.memberIds)")
        }
        XCTAssertEqual(clusters.reduce(0) { $0 + $1.size }, lib.count, "elk punt toegewezen")
    }
}
