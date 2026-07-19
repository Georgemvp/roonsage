@testable import RoonSageCore
import XCTest

/// Feature 2 — taste-representative seed selection. The outward discovery producers
/// expand from these seeds, so ranking them by CLAP taste centrality (not raw play
/// count) is what makes discovery taste-driven.
final class TasteSeedsTests: XCTestCase {

    private func track(_ id: String, artist: String, _ emb: [Float]) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(
            id: id, title: id, artist: artist, album: "Al", imageKey: nil, matchKey: id,
            bpm: 120, camelot: "8B", rmsEnergy: 0.5, tags: [], embedding: emb)
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
                                              rmsEnergy: 0.5, tags: [])]   // no embedding
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

    // MARK: diversifiedSeeds — mixing taste core with a rotating periphery

    /// The core (most-central artists) is kept, in order, first; the explore slice
    /// comes strictly from beyond the core and is deterministic per salt.
    func testDiversifiedSeedsKeepsCoreAndAddsPeriphery() {
        let lib = (0..<20).map { track("t\($0)", artist: String(format: "A%02d", $0), [Float(20 - $0), 1, 0]) }
        let taste: [Float] = [1, 0, 0]
        let core = TasteSeeds.rankArtists(library: lib, tasteVector: taste, playCountByArtist: [:], limit: 4)
        let seeds = TasteSeeds.diversifiedSeeds(
            library: lib, tasteVector: taste, playCountByArtist: [:],
            limit: 6, exploreCount: 2, salt: "2026-W27")
        XCTAssertEqual(seeds.count, 6)
        XCTAssertEqual(Array(seeds.prefix(4)), core, "the taste core is kept, in order, first")
        XCTAssertTrue(Set(seeds.suffix(2)).isDisjoint(with: Set(core)), "explore slice comes from beyond the core")
        let again = TasteSeeds.diversifiedSeeds(
            library: lib, tasteVector: taste, playCountByArtist: [:],
            limit: 6, exploreCount: 2, salt: "2026-W27")
        XCTAssertEqual(seeds, again, "same salt → same seeds")
    }

    /// A different salt rotates a different periphery slice in, while the core stays put.
    func testDiversifiedSeedsRotatePeripheryWithSalt() {
        let lib = (0..<40).map { track("t\($0)", artist: String(format: "A%02d", $0), [Float(40 - $0), 1, 0]) }
        let taste: [Float] = [1, 0, 0]
        let w27 = TasteSeeds.diversifiedSeeds(library: lib, tasteVector: taste, playCountByArtist: [:],
                                              limit: 10, exploreCount: 5, salt: "2026-W27")
        let w28 = TasteSeeds.diversifiedSeeds(library: lib, tasteVector: taste, playCountByArtist: [:],
                                              limit: 10, exploreCount: 5, salt: "2026-W28")
        XCTAssertEqual(Array(w27.prefix(5)), Array(w28.prefix(5)), "the taste core is stable week-to-week")
        XCTAssertNotEqual(Set(w27.suffix(5)), Set(w28.suffix(5)), "the periphery slice rotates by salt")
    }

    /// Too few artists to have a periphery → plain core ranking (no crash, no dupes).
    func testDiversifiedSeedsFallsBackToCoreWhenPoolSmall() {
        let lib = (0..<3).map { track("t\($0)", artist: "A\($0)", [Float(3 - $0), 1, 0]) }
        let taste: [Float] = [1, 0, 0]
        let seeds = TasteSeeds.diversifiedSeeds(library: lib, tasteVector: taste, playCountByArtist: [:],
                                                limit: 6, exploreCount: 3, salt: "x")
        let core = TasteSeeds.rankArtists(library: lib, tasteVector: taste, playCountByArtist: [:], limit: 6)
        XCTAssertEqual(seeds, core, "too few artists to diversify → plain core ranking")
    }
}
