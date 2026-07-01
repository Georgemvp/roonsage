@testable import RoonSageCore
import XCTest

/// Feature 2 — taste-representative seed selection. The outward discovery producers
/// expand from these seeds, so ranking them by CLAP taste centrality (not raw play
/// count) is what makes discovery taste-driven.
final class TasteSeedsTests: XCTestCase {

    private func track(_ id: String, artist: String, _ emb: [Float]) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(
            id: id, title: id, artist: artist, album: "Al", imageKey: nil, matchKey: id,
            bpm: 120, camelot: "8B", energy: 0.5, tags: [], embedding: emb)
    }

    func testTasteAlignedArtistRanksAboveOrthogonal() {
        let lib = [track("a1", artist: "Aligned", [1, 0, 0]),
                   track("o1", artist: "Ortho", [0, 1, 0])]
        let ranked = TasteSeeds.rankArtists(
            library: lib, tasteVector: [1, 0, 0], playCountByArtist: [:], limit: 10)
        XCTAssertEqual(ranked.first, "Aligned", "artist whose sound matches the taste vector leads")
        XCTAssertEqual(ranked, ["Aligned", "Ortho"])
    }

    func testPlayCountBreaksTiesUpward() {
        // Two artists equally taste-aligned; the more-played one ranks higher.
        let lib = [track("x1", artist: "Heavy", [1, 0, 0]),
                   track("y1", artist: "Light", [1, 0, 0])]
        let ranked = TasteSeeds.rankArtists(
            library: lib, tasteVector: [1, 0, 0],
            playCountByArtist: ["heavy": 50, "light": 1], limit: 10)
        XCTAssertEqual(ranked, ["Heavy", "Light"], "play count nudges an equally-aligned artist up")
    }

    func testArtistsWithoutEmbeddingsDropped() {
        let lib = [track("a1", artist: "Has", [1, 0, 0]),
                   DatabaseManager.SonicTrack(id: "n1", title: "n", artist: "None", album: nil,
                                              imageKey: nil, matchKey: "n1", bpm: 120, camelot: "8B",
                                              energy: 0.5, tags: [])]   // no embedding
        let ranked = TasteSeeds.rankArtists(
            library: lib, tasteVector: [1, 0, 0], playCountByArtist: [:], limit: 10)
        XCTAssertEqual(ranked, ["Has"], "an artist with no embedded track has no CLAP signal to rank on")
    }

    func testRespectsLimitAndIsDeterministic() {
        let lib = (0..<10).map { track("t\($0)", artist: "Artist\($0)", [Float($0) + 1, 1, 0]) }
        let a = TasteSeeds.rankArtists(library: lib, tasteVector: [1, 0, 0], playCountByArtist: [:], limit: 3)
        let b = TasteSeeds.rankArtists(library: lib, tasteVector: [1, 0, 0], playCountByArtist: [:], limit: 3)
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(a, b, "same inputs → same ranking")
    }

    func testEmptyTasteVectorYieldsNothing() {
        let lib = [track("a1", artist: "A", [1, 0, 0])]
        XCTAssertTrue(TasteSeeds.rankArtists(library: lib, tasteVector: [], playCountByArtist: [:], limit: 5).isEmpty)
    }
}
