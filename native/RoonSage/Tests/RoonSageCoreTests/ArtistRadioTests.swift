@testable import RoonSageCore
import XCTest

/// AI artist radios → Qobuz: the pure, deterministic helpers (track capping +
/// defensive LLM-JSON parsing). Network + LLM paths are exercised in the app.
final class ArtistRadioTests: XCTestCase {

    private func track(_ id: String, _ artist: String) -> TrackRecord {
        TrackRecord(id: id, title: "T-\(id)", artist: artist)
    }

    // MARK: capForPlaylist

    func testCapLimitsNonSeedArtistsButExemptsSeed() {
        // 10 seed-artist tracks + 10 from one other artist.
        var pool = (0..<10).map { track("seed\($0)", "Seed") }
        pool += (0..<10).map { track("other\($0)", "Other") }

        let out = RoonClient.capForPlaylist(
            pool, seedArtist: "Seed", minTracks: 5, maxTracks: 30, maxPerArtist: 3)

        let seedCount = out.filter { $0.artist == "Seed" }.count
        let otherCount = out.filter { $0.artist == "Other" }.count
        XCTAssertEqual(seedCount, 10, "seed artist is exempt from the per-artist cap")
        XCTAssertEqual(otherCount, 3, "non-seed artist capped at maxPerArtist")
        XCTAssertEqual(out.count, 13)
    }

    func testCapStopsAtMaxTracks() {
        let pool = (0..<100).map { track("seed\($0)", "Seed") }
        let out = RoonClient.capForPlaylist(
            pool, seedArtist: "Seed", minTracks: 20, maxTracks: 30, maxPerArtist: 3)
        XCTAssertEqual(out.count, 30, "never exceeds maxTracks")
    }

    func testCapTopsUpToMinFromSkipped() {
        // Many distinct artists, one track each, but the per-artist cap would
        // otherwise leave too few once a couple repeat — ensure top-up reaches min.
        var pool = (0..<4).map { track("a\($0)", "A") }   // 4 from artist A (cap 1 → 3 skipped)
        pool += (0..<3).map { track("b\($0)", "Artist\($0)") }   // 3 unique

        let out = RoonClient.capForPlaylist(
            pool, seedArtist: "Seed", minTracks: 5, maxTracks: 30, maxPerArtist: 1)
        XCTAssertGreaterThanOrEqual(out.count, 5, "tops up from skipped to reach minTracks")
    }

    // MARK: parseTitleJSON

    func testParseCleanJSON() {
        let (t, d) = RoonClient.parseTitleJSON(
            #"{"title": "Nachtelijke Dwaling", "description": "Donkere, dromerige radio."}"#,
            fallbackTitle: "FB", fallbackDesc: "FBD")
        XCTAssertEqual(t, "Nachtelijke Dwaling")
        XCTAssertEqual(d, "Donkere, dromerige radio.")
    }

    func testParseFencedAndChattyJSON() {
        let raw = """
        Hier is je playlist:
        ```json
        {"title": "Gouden Uren", "description": "Warme klanken voor de avond."}
        ```
        """
        let (t, d) = RoonClient.parseTitleJSON(raw, fallbackTitle: "FB", fallbackDesc: "FBD")
        XCTAssertEqual(t, "Gouden Uren")
        XCTAssertEqual(d, "Warme klanken voor de avond.")
    }

    func testParseFallsBackOnGarbage() {
        let (t, d) = RoonClient.parseTitleJSON(
            "sorry, ik kan dat niet", fallbackTitle: "FB", fallbackDesc: "FBD")
        XCTAssertEqual(t, "FB")
        XCTAssertEqual(d, "FBD")
    }

    func testParseFallsBackPerMissingField() {
        let (t, d) = RoonClient.parseTitleJSON(
            #"{"title": "  "}"#, fallbackTitle: "FB", fallbackDesc: "FBD")
        XCTAssertEqual(t, "FB", "blank title → fallback")
        XCTAssertEqual(d, "FBD", "missing description → fallback")
    }

    // MARK: stable Qobuz name

    func testQobuzPlaylistNameIsStablePrefix() {
        XCTAssertEqual(RoonClient.qobuzPlaylistName(for: "Gouden Uren"), "RoonSage · Gouden Uren")
    }
}
