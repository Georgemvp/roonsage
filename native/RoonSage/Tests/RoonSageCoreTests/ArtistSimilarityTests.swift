import XCTest
@testable import RoonSageCore

final class ArtistSimilarityTests: XCTestCase {
    private func track(_ id: String, artist: String, emb: [Float]) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(id: id, title: id, artist: artist, album: nil, imageKey: nil,
                                   matchKey: id, bpm: 120, camelot: "8B", rmsEnergy: 0.5, tags: [],
                                   embedding: emb)
    }

    func testRanksCloserArtistHigher() {
        // A clusters near X; B is orthogonal.
        let tracks = [
            track("x1", artist: "X", emb: [1, 0, 0]),
            track("x2", artist: "X", emb: [0.95, 0.31, 0]),
            track("a1", artist: "A", emb: [0.9, 0.43, 0]),
            track("a2", artist: "A", emb: [0.97, 0.24, 0]),
            track("b1", artist: "B", emb: [0, 0, 1]),
            track("b2", artist: "B", emb: [0, 0.1, 0.99]),
        ]
        let results = ArtistSimilarity.similarArtists(to: "X", tracks: tracks, limit: 5)
        XCTAssertEqual(results.first?.name, "A")
        XCTAssertFalse(results.contains { $0.name == "X" }, "never recommends itself")
        XCTAssertFalse(results.contains { $0.name == "B" }, "orthogonal artist falls under the score floor")
    }

    func testMedoidPicksCentralMember() {
        let vecs: [[Float]] = [
            VectorIndex.normalized([1, 0, 0]),
            VectorIndex.normalized([0.9, 0.44, 0]),   // central-ish
            VectorIndex.normalized([0.8, 0.6, 0]),
        ]
        let m = ArtistSimilarity.medoid(of: vecs)
        XCTAssertEqual(m, vecs[1], "middle vector minimizes summed distance")
    }

    func testChamferSymmetricAndBounded() {
        let a: [[Float]] = [VectorIndex.normalized([1, 0]), VectorIndex.normalized([0.9, 0.44])]
        let b: [[Float]] = [VectorIndex.normalized([0.95, 0.31])]
        let ab = ArtistSimilarity.chamfer(a, b)
        let ba = ArtistSimilarity.chamfer(b, a)
        XCTAssertEqual(ab, ba, accuracy: 1e-9)
        XCTAssertGreaterThan(ab, 0.9)
        XCTAssertLessThanOrEqual(ab, 1.0001)
    }

    func testUnknownArtistOrNoEmbeddingsReturnsEmpty() {
        XCTAssertTrue(ArtistSimilarity.similarArtists(to: "Nope", tracks: []).isEmpty)
        let noEmb = [DatabaseManager.SonicTrack(id: "t", title: "t", artist: "X", album: nil,
                                                imageKey: nil, matchKey: "t", bpm: nil, camelot: "",
                                                rmsEnergy: nil, tags: [])]
        XCTAssertTrue(ArtistSimilarity.similarArtists(to: "X", tracks: noEmb).isEmpty)
    }
}
