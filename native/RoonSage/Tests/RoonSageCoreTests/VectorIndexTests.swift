@testable import RoonSageCore
import XCTest

/// Track E5d — brute-force cosine k-NN over CLAP embeddings.
final class VectorIndexTests: XCTestCase {
    private func track(_ id: String, _ emb: [Float]) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(
            id: id, title: id, artist: "A", album: "Al", imageKey: nil, matchKey: id,
            bpm: 120, camelot: "8B", energy: 0.5, tags: [], embedding: emb)
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

    func testNilWithoutEmbeddings() {
        XCTAssertNil(VectorIndex(tracks: [track("a", []), track("b", [])]),
                     "no embeddings -> no index")
    }
}
