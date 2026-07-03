import XCTest
@testable import RoonSageCore

final class SonicSelectionTests: XCTestCase {
    private func track(_ id: String, title: String? = nil, artist: String = "artist",
                       album: String? = nil, emb: [Float]) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(id: id, title: title ?? id, artist: artist, album: album,
                                   imageKey: nil, matchKey: id, bpm: 120, camelot: "8B",
                                   energy: 0.5, tags: [], embedding: emb)
    }

    private func index(_ tracks: [DatabaseManager.SonicTrack]) -> VectorIndex {
        VectorIndex(tracks: tracks)!
    }

    func testDropsEmbeddingNearDuplicate() {
        // Same recording on an album and a compilation: nearly identical vectors,
        // different titles (remaster suffix) so metadata doesn't catch it.
        let a = track("orig", title: "Song", emb: [1, 0, 0])
        let dup = track("comp", title: "Song (Remastered 2011)", emb: [0.999, 0.02, 0])
        let other = track("other", title: "Different", emb: [0, 1, 0])
        let idx = index([a, dup, other])
        let hits = idx.nearest(to: [1, 0, 0], k: 3)
        let kept = SonicSelection.dropNearDuplicates(hits, index: idx, limit: 3)
        XCTAssertEqual(kept.map { $0.track.id }, ["orig", "other"],
                       "the compilation copy of the same recording is dropped")
    }

    func testDropsMetadataDuplicateEvenWhenVectorsDiffer() {
        // Two masters of the same song whose embeddings drifted apart a bit —
        // the normalized title|artist check still collapses them.
        let a = track("v1", title: "Song", emb: [1, 0, 0])
        let b = track("v2", title: "song ", emb: [0.6, 0.8, 0]) // cos 0.6 — below the bar
        let idx = index([a, b])
        let hits = idx.nearest(to: [1, 0, 0], k: 2)
        let kept = SonicSelection.dropNearDuplicates(hits, index: idx, limit: 2)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.track.id, "v1")
    }

    func testRespectsLimitAndOrder() {
        let tracks = (0..<6).map { i -> DatabaseManager.SonicTrack in
            var e = [Float](repeating: 0, count: 6); e[i] = 1
            return track("t\(i)", title: "t\(i)", emb: e)
        }
        let idx = index(tracks)
        let hits = idx.nearest(to: [1, 0.1, 0.1, 0.1, 0.1, 0.1], k: 6)
        let kept = SonicSelection.dropNearDuplicates(hits, index: idx, limit: 3)
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(kept.map { $0.track.id }, hits.prefix(3).map { $0.track.id },
                       "no duplicates → same ranking, just truncated")
    }

    func testMMRHardRejectsNearDuplicateEvenAtHighLambda() {
        // λ≈1 turns the soft diversity penalty off; only the hard constraint
        // can stop the duplicate from taking slot 2.
        func item(_ id: String, _ e: [Float], _ rel: Double, album: String? = nil)
            -> (DatabaseManager.SonicTrack, [Float], Double) {
            (track(id, album: album, emb: e), VectorIndex.normalized(e), rel)
        }
        let items = [
            item("a1", [1, 0, 0], 1.0),
            item("dup", [0.999, 0.03, 0], 0.99),   // cos > 0.95 with a1
            item("b1", [0, 1, 0], 0.5),
        ]
        let picked = RadioEngine.mmr(items, limit: 2, lambda: 0.98)
        XCTAssertEqual(picked.map(\.id), ["a1", "b1"],
                       "same-recording candidate is rejected outright")
    }

    func testMMRSoftPenalizesSameAlbum() {
        // Three tracks off one album, sonically spread out (so plain MMR would
        // happily take them all), vs. an equally relevant track off another
        // album — the album penalty should let the outsider in before album
        // track #3.
        func item(_ id: String, _ e: [Float], _ rel: Double, _ album: String)
            -> (DatabaseManager.SonicTrack, [Float], Double) {
            (track(id, artist: "A", album: album, emb: e), VectorIndex.normalized(e), rel)
        }
        let items = [
            item("x1", [1, 0, 0, 0], 1.0, "X"),
            item("x2", [0, 1, 0, 0], 0.9, "X"),
            item("x3", [0, 0, 1, 0], 0.85, "X"),
            item("y1", [0, 0, 0, 1], 0.8, "Y"),
        ]
        let picked = RadioEngine.mmr(items, limit: 3, lambda: 0.9)
        XCTAssertTrue(picked.map(\.id).contains("y1"),
                      "a third same-album pick loses to the other album: \(picked.map(\.id))")
    }
}
