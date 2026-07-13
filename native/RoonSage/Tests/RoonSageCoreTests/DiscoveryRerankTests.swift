import XCTest
@testable import RoonSageCore

final class DiscoveryRerankTests: XCTestCase {
    private struct Item { let artist: String; let genres: [String]; let score: Double }

    private func mmr(_ items: [Item], limit: Int, lambda: Double = DiscoveryRerank.diversityWeight) -> [Item] {
        DiscoveryRerank.mmr(items, limit: limit,
                            relevance: { $0.score }, artist: { $0.artist }, genres: { $0.genres }, lambda: lambda)
    }

    /// Distinct items with no genre overlap → MMR leaves the relevance order intact.
    func testDistinctItemsKeepRelevanceOrder() {
        let items = [Item(artist: "A", genres: ["rock"], score: 0.9),
                     Item(artist: "B", genres: ["jazz"], score: 0.8),
                     Item(artist: "C", genres: ["ambient"], score: 0.7)]
        XCTAssertEqual(mmr(items, limit: 3).map { $0.artist }, ["A", "B", "C"])
    }

    /// Same-artist clustering: a plain top-2 would be A,A. MMR defers the near-
    /// duplicate A for the equally-on-taste but distinct B.
    func testSameArtistIsDeferred() {
        let items = [Item(artist: "A", genres: ["rock"], score: 0.90),
                     Item(artist: "A", genres: ["rock"], score: 0.85),
                     Item(artist: "A", genres: ["rock"], score: 0.80),
                     Item(artist: "B", genres: ["jazz"], score: 0.78)]
        let out = mmr(items, limit: 2)
        XCTAssertEqual(out[0].artist, "A")   // highest relevance first
        XCTAssertEqual(out[1].artist, "B")   // distinct B beats a 3rd A-clone
    }

    /// The first pick is always the highest-relevance item, whatever the overlap.
    func testFirstPickIsHighestRelevance() {
        let items = [Item(artist: "B", genres: ["rock"], score: 0.95),
                     Item(artist: "A", genres: ["rock"], score: 0.60)]  // pre-sorted desc
        XCTAssertEqual(mmr(items, limit: 1).first?.artist, "B")
    }

    /// Genre-neighbourhood diversity: with close scores a different-genre pick is
    /// preferred over a same-genre near-duplicate.
    func testGenreNeighbourhoodDiversified() {
        let items = [Item(artist: "A", genres: ["techno", "electronic"], score: 0.90),
                     Item(artist: "B", genres: ["techno", "electronic"], score: 0.88),
                     Item(artist: "C", genres: ["folk"], score: 0.85)]
        let out = mmr(items, limit: 2)
        XCTAssertEqual(out[0].artist, "A")
        XCTAssertEqual(out[1].artist, "C")   // folk (distinct) over B (same techno/electronic)
    }

    /// limit > input returns all (reordered); limit 0 and empty input → empty.
    func testEdgeCases() {
        let items = [Item(artist: "A", genres: [], score: 0.9), Item(artist: "B", genres: [], score: 0.8)]
        XCTAssertEqual(mmr(items, limit: 5).count, 2)
        XCTAssertTrue(mmr(items, limit: 0).isEmpty)
        XCTAssertTrue(mmr([], limit: 3).isEmpty)
    }

    /// similarity(): same artist = 1, genre Jaccard otherwise, no-genre = 0.
    func testSimilarity() {
        XCTAssertEqual(DiscoveryRerank.similarity(artistA: "a", genresA: ["rock"], artistB: "a", genresB: ["jazz"]), 1)
        XCTAssertEqual(DiscoveryRerank.similarity(artistA: "a", genresA: ["rock", "pop"], artistB: "b", genresB: ["rock"]),
                       0.5, accuracy: 1e-9)
        XCTAssertEqual(DiscoveryRerank.similarity(artistA: "a", genresA: [], artistB: "b", genresB: ["rock"]), 0)
    }
}
