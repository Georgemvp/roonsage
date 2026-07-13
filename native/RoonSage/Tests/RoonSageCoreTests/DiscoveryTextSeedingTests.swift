import XCTest
@testable import RoonSageCore

final class DiscoveryTextSeedingTests: XCTestCase {

    func testRanksByMeanScoreWithMinTracks() {
        // A: two hits mean 0.8; B: two hits mean 0.6; C: one hit (below minTracks=2).
        let hits: [(artist: String?, score: Float)] = [
            ("A", 0.9), ("A", 0.7), ("B", 0.6), ("B", 0.6), ("C", 0.99),
        ]
        XCTAssertEqual(DiscoveryTextSeeding.topArtists(hits, limit: 10), ["A", "B"])
    }

    func testCaseInsensitiveAggregationKeepsDisplayCase() {
        let hits: [(artist: String?, score: Float)] = [("Boards of Canada", 0.8), ("boards of canada", 0.8)]
        XCTAssertEqual(DiscoveryTextSeeding.topArtists(hits, limit: 5), ["Boards of Canada"])
    }

    func testLimitAndEmptyInputs() {
        let hits: [(artist: String?, score: Float)] = [("A", 0.9), ("A", 0.9), ("B", 0.8), ("B", 0.8)]
        XCTAssertEqual(DiscoveryTextSeeding.topArtists(hits, limit: 1), ["A"])
        XCTAssertTrue(DiscoveryTextSeeding.topArtists(hits, limit: 0).isEmpty)
        XCTAssertTrue(DiscoveryTextSeeding.topArtists([], limit: 5).isEmpty)
    }

    func testNilAndBlankArtistsIgnored() {
        let hits: [(artist: String?, score: Float)] = [
            (nil, 0.9), ("  ", 0.9), ("A", 0.8), ("A", 0.8),
        ]
        XCTAssertEqual(DiscoveryTextSeeding.topArtists(hits, limit: 5), ["A"])
    }

    func testTieBreakIsStableByDisplay() {
        // Equal means → alphabetical display case decides, deterministically.
        let hits: [(artist: String?, score: Float)] = [("Zed", 0.8), ("Zed", 0.8), ("Abe", 0.8), ("Abe", 0.8)]
        XCTAssertEqual(DiscoveryTextSeeding.topArtists(hits, limit: 2), ["Abe", "Zed"])
    }
}
