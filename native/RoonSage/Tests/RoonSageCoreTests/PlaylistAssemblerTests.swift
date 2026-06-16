@testable import RoonSageCore
import XCTest

/// Deterministic post-LLM curation pass: dedup, per-artist cap, no back-to-back
/// artists, top-up to target, and soft preferred/anti-repeat ordering.
final class PlaylistAssemblerTests: XCTestCase {
    private func track(_ id: String, artist: String, key: String? = nil) -> TrackRecord {
        TrackRecord(id: id, title: id, artist: artist, matchKey: key ?? id)
    }

    func testDedupsByIdentity() {
        let picks = [track("a", artist: "A", key: "k1"),
                     track("a2", artist: "A2", key: "k1")]  // same match key → duplicate
        let out = PlaylistAssembler.assemble(llmPicks: picks, pool: [], target: 10)
        XCTAssertEqual(out.count, 1, "tracks sharing a match key collapse to one")
    }

    func testEnforcesMaxPerArtist() {
        let picks = (1...5).map { track("s\($0)", artist: "Same", key: "s\($0)") }
        let out = PlaylistAssembler.assemble(llmPicks: picks, pool: [], target: 10, maxPerArtist: 2)
        XCTAssertEqual(out.filter { $0.artist == "Same" }.count, 2, "capped at 2 per artist")
    }

    func testNoConsecutiveSameArtist() {
        // LLM clustered the same artist together; the assembler must spread them.
        let picks = [track("a1", artist: "A", key: "a1"), track("a2", artist: "A", key: "a2"),
                     track("b1", artist: "B", key: "b1"), track("c1", artist: "C", key: "c1")]
        let out = PlaylistAssembler.assemble(llmPicks: picks, pool: [], target: 4, maxPerArtist: 2)
        for i in 1..<out.count {
            XCTAssertNotEqual(out[i].artist, out[i - 1].artist, "no two consecutive same-artist tracks")
        }
    }

    func testTopsUpFromPoolWhenLLMUnderDelivers() {
        let picks = [track("a", artist: "A", key: "a")]            // LLM gave only 1
        let pool = (1...10).map { track("p\($0)", artist: "P\($0)", key: "p\($0)") }
        let out = PlaylistAssembler.assemble(llmPicks: picks, pool: pool, target: 5)
        XCTAssertEqual(out.count, 5, "topped up to the target from the pool")
        XCTAssertEqual(out.first?.id, "a", "LLM pick keeps priority")
    }

    func testEmptyPicksFallsBackToPool() {
        let pool = (1...8).map { track("p\($0)", artist: "P\($0)", key: "p\($0)") }
        let out = PlaylistAssembler.assemble(llmPicks: [], pool: pool, target: 5)
        XCTAssertEqual(out.count, 5, "produces a playlist purely from the ranked pool")
    }

    func testDeprioritizedUsedOnlyWhenNeeded() {
        // Two fresh + the rest recently used; target 3 should prefer the fresh ones.
        let fresh = [track("f1", artist: "F1", key: "f1"), track("f2", artist: "F2", key: "f2")]
        let recent = (1...5).map { track("r\($0)", artist: "R\($0)", key: "r\($0)") }
        let out = PlaylistAssembler.assemble(
            llmPicks: [], pool: fresh + recent, target: 2,
            deprioritized: Set(recent.map { PlaylistAssembler.identity($0) })
        )
        XCTAssertEqual(Set(out.map(\.id)), ["f1", "f2"], "fresh tracks chosen before recently-used ones")
    }

    func testPreferredArtistFloatsForwardInTopUp() {
        let pool = [track("x", artist: "Nobody", key: "x"), track("y", artist: "Loved", key: "y")]
        let out = PlaylistAssembler.assemble(
            llmPicks: [], pool: pool, target: 2, preferredArtists: ["loved"]
        )
        XCTAssertEqual(out.first?.id, "y", "preferred-artist track ordered first in top-up")
    }
}
