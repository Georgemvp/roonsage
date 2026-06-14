@testable import RoonSageCore
import XCTest

/// Track E6 — hybrid AI retrieval: LLM-filtered candidates reranked by cosine
/// closeness to the request's CLAP text embedding, with a per-artist cap.
final class HybridRerankTests: XCTestCase {
    private func track(_ id: String, artist: String, key: String) -> TrackRecord {
        TrackRecord(id: id, title: id, artist: artist, matchKey: key)
    }

    func testRanksByCosineToQuery() {
        let tracks = [track("c", artist: "C", key: "c"),
                      track("a", artist: "A", key: "a"),
                      track("b", artist: "B", key: "b")]
        let emb: [String: [Float]] = [
            "a": [1, 0, 0, 0],
            "b": [0.9, 0.1, 0, 0],   // close to query
            "c": [0, 1, 0, 0],       // orthogonal
        ]
        let out = RoonClient.rankCandidates(tracks, queryVec: [1, 0, 0, 0],
                                            embByKey: emb, limit: 10, maxPerArtist: 5)
        XCTAssertEqual(out.map(\.id), ["a", "b", "c"], "ordered by cosine to the query")
    }

    func testArtistCapLimitsClustering() {
        let tracks = [track("a1", artist: "Same", key: "a1"),
                      track("a2", artist: "Same", key: "a2"),
                      track("b", artist: "Other", key: "b")]
        let emb: [String: [Float]] = [
            "a1": [1, 0], "a2": [0.99, 0.01], "b": [0.95, 0.05],
        ]
        let out = RoonClient.rankCandidates(tracks, queryVec: [1, 0],
                                            embByKey: emb, limit: 10, maxPerArtist: 1)
        XCTAssertEqual(out.count, 2, "max one track per artist")
        XCTAssertEqual(out.filter { $0.artist == "Same" }.count, 1)
    }

    func testDropsCandidatesWithoutEmbedding() {
        let tracks = [track("a", artist: "A", key: "a"),
                      track("x", artist: "X", key: "missing")]
        let out = RoonClient.rankCandidates(tracks, queryVec: [1, 0],
                                            embByKey: ["a": [1, 0]], limit: 10, maxPerArtist: 5)
        XCTAssertEqual(out.map(\.id), ["a"], "candidate without an embedding is dropped")
    }
}
