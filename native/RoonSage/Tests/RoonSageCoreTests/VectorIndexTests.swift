@testable import RoonSageCore
import XCTest

/// Track E5d — brute-force cosine k-NN over CLAP embeddings.
final class VectorIndexTests: XCTestCase {
    private func track(_ id: String, _ emb: [Float]) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(
            id: id, title: id, artist: "A", album: "Al", imageKey: nil, matchKey: id,
            bpm: 120, camelot: "8B", rmsEnergy: 0.5, tags: [], embedding: emb)
    }

    func testNearestRanksByCosine() throws {
        let idx = try XCTUnwrap(VectorIndex(tracks: [
            track("x", [1, 0, 0, 0]),
            track("x2", [0.95, 0.05, 0, 0]),   // close to x
            track("y", [0, 1, 0, 0]),          // orthogonal
            track("z", [0, 0, 1, 0]),
        ]))
        let hits = idx.nearest(toId: "x", k: 2)
        XCTAssertEqual(hits.first?.track.id, "x2", "closest neighbour by cosine")
        XCTAssertFalse(hits.contains { $0.track.id == "x" }, "seed excluded")
        XCTAssertGreaterThan(hits.first!.score, hits.last!.score)
    }

    func testCentroidQuery() throws {
        let idx = try XCTUnwrap(VectorIndex(tracks: [
            track("a", [1, 0, 0, 0]),
            track("b", [0, 1, 0, 0]),
            track("c", [1, 1, 0, 0]),   // points toward the a+b centroid
            track("d", [0, 0, 1, 0]),
        ]))
        let centroid = try XCTUnwrap(idx.centroid(ofIds: ["a", "b"]))
        let hits = idx.nearest(to: centroid, k: 1, excludingIds: ["a", "b"])
        XCTAssertEqual(hits.first?.track.id, "c", "centroid of a,b nearest to c")
    }

    func testWeightedCentroidLeansToTheHeavierSeed() throws {
        // Guards the in-place vsma scalar-weight accumulate: weighting a,b as 3:1
        // must pull the centroid toward a (nearest "ca"), and 1:3 toward b ("cb").
        let idx = try XCTUnwrap(VectorIndex(tracks: [
            track("a", [1, 0, 0, 0]),
            track("b", [0, 1, 0, 0]),
            track("ca", [1, 0.2, 0, 0]),   // a-heavy
            track("cb", [0.2, 1, 0, 0]),   // b-heavy
        ]))
        let towardA = try XCTUnwrap(idx.centroid(ofIds: ["a", "b"], weights: [3, 1]))
        XCTAssertEqual(idx.nearest(to: towardA, k: 1, excludingIds: ["a", "b"]).first?.track.id, "ca")
        let towardB = try XCTUnwrap(idx.centroid(ofIds: ["a", "b"], weights: [1, 3]))
        XCTAssertEqual(idx.nearest(to: towardB, k: 1, excludingIds: ["a", "b"]).first?.track.id, "cb")
    }

    func testNNSimilarityStatsAreFiniteAndInRange() throws {
        // Guards the reused scores buffer in nnSimilarityStats: a corrupted buffer
        // would yield out-of-range / NaN cosine stats. Needs >= 10 embedded tracks.
        let tracks = (0..<12).map { i -> DatabaseManager.SonicTrack in
            var e = [Float](repeating: 0, count: 4)
            e[i % 4] = 1; e[(i + 1) % 4] = 0.3
            return track("t\(i)", e)
        }
        let idx = try XCTUnwrap(VectorIndex(tracks: tracks))
        let stats = try XCTUnwrap(idx.nnSimilarityStats(sampleCount: 12))
        XCTAssertTrue(stats.mean.isFinite && stats.mean >= -1.0001 && stats.mean <= 1.0001)
        XCTAssertTrue(stats.std.isFinite && stats.std >= 0)
    }

    func testNilWithoutEmbeddings() {
        XCTAssertNil(VectorIndex(tracks: [track("a", []), track("b", [])]),
                     "no embeddings -> no index")
    }
}
