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
}
