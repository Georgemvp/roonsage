@testable import RoonSageCore
import XCTest

/// Track E5d — Similar / Fingerprint / Alchemy / Song Path use the CLAP
/// VectorIndex when one is supplied, and fall back to rule-based otherwise.
final class SonicEngineEmbeddingTests: XCTestCase {
    private func track(_ id: String, _ emb: [Float], camelot: String = "8B", bpm: Double = 120) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(
            id: id, title: id, artist: id, album: "Al", imageKey: nil, matchKey: id,
            bpm: bpm, camelot: camelot, energy: 0.5, tags: [], embedding: emb)
    }

    private func lib() -> [DatabaseManager.SonicTrack] {
        [track("x", [1, 0, 0, 0]),
         track("x2", [0.96, 0.28, 0, 0]),
         track("y", [0, 1, 0, 0]),
         track("z", [0, 0, 1, 0])]
    }

    func testSimilarUsesEmbeddingIndex() throws {
        let tracks = lib()
        let index = try XCTUnwrap(VectorIndex(tracks: tracks))
        let hits = SonicEngine.similar(to: tracks[0], in: tracks, limit: 2, index: index)
        XCTAssertEqual(hits.first?.track.id, "x2", "cosine-nearest neighbour")
    }

    func testAlchemyUsesEmbeddingIndex() throws {
        let tracks = lib()
        let index = try XCTUnwrap(VectorIndex(tracks: tracks))
        // add x, subtract y -> push toward x, away from y; x2 (mostly-x) should win.
        let r = SonicEngine.alchemy(add: [tracks[0]], subtract: [tracks[2]],
                                    in: tracks, limit: 3, index: index)
        XCTAssertEqual(r.first?.track.id, "x2")
        XCTAssertFalse(r.contains { $0.track.id == "x" }, "add seed excluded")
    }

    func testSongPathEmbeddingEndpointsAndBridge() throws {
        let tracks = lib()
        let index = try XCTUnwrap(VectorIndex(tracks: tracks))
        let path = SongPaths.find(from: tracks[0], to: tracks[2], library: tracks,
                                  maxSteps: 4, index: index)
        XCTAssertEqual(path.first?.track.id, "x")
        XCTAssertEqual(path.last?.track.id, "y")
        XCTAssertGreaterThanOrEqual(path.count, 2)
    }

    func testFallsBackWithoutIndex() {
        let tracks = lib()
        // No index -> rule-based path still returns results (all same camelot/bpm here).
        let hits = SonicEngine.similar(to: tracks[0], in: tracks, limit: 2)
        XCTAssertFalse(hits.isEmpty)
    }
}
