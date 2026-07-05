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

    func testCapAppliesSeedCap() {
        var pool = (0..<20).map { track("seed\($0)", "Seed") }
        pool += (0..<20).map { track("n\($0)", "Neighbour\($0)") }
        let out = RoonClient.capForPlaylist(
            pool, seedArtist: "Seed", minTracks: 20, maxTracks: 30, maxPerArtist: 3, seedCap: 10)
        XCTAssertEqual(out.filter { $0.artist == "Seed" }.count, 10, "seed artist capped at seedCap")
        XCTAssertEqual(out.count, 30)
    }

    func testCapDedupesVersionsOfSameSong() {
        let pool = [
            TrackRecord(id: "1", title: "I'll Keep Loving You", artist: "Guetta"),
            TrackRecord(id: "2", title: "I'll Keep Loving You (feat. Birdy)", artist: "Guetta"),
            TrackRecord(id: "3", title: "I'll Keep Loving You [Radio Edit]", artist: "Guetta"),
            TrackRecord(id: "4", title: "Other Song", artist: "Guetta"),
        ]
        let out = RoonClient.capForPlaylist(
            pool, seedArtist: "Seed", minTracks: 1, maxTracks: 30, maxPerArtist: 3)
        let titles = out.filter { $0.artist == "Guetta" }.map(\.title)
        XCTAssertEqual(titles.count, 2, "three editions of one song collapse to one + the other song")
    }

    func testTitleDedupKeyStripsQualifiers() {
        XCTAssertEqual(RoonClient.titleDedupKey("This Ain't a Love Song [Album Version]"), "this ain't a love song")
        XCTAssertEqual(RoonClient.titleDedupKey("Get Lucky (feat. Pharrell)"), "get lucky")
        XCTAssertEqual(RoonClient.titleDedupKey("Plain Title"), "plain title")
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

    // MARK: parseTitleArray (batch)

    func testParseTitleArrayMapsByIndex() {
        let raw = """
        [
          {"i": 0, "title": "Dromerige indie", "description": "Zachte gitaren."},
          {"i": 2, "title": "Strakke techno", "description": "Peak-time."},
          {"i": 1, "title": "Warme soul", "description": "Groovy avond."}
        ]
        """
        let out = RoonClient.parseTitleArray(raw, count: 3)
        XCTAssertEqual(out[0]?.title, "Dromerige indie")
        XCTAssertEqual(out[1]?.title, "Warme soul")
        XCTAssertEqual(out[2]?.title, "Strakke techno")
    }

    func testParseTitleArrayFencedAndClamps() {
        let long = String(repeating: "a", count: 60)
        let raw = "```json\n[{\"i\":0,\"title\":\"\(long)\",\"description\":\"x\"}]\n```"
        let out = RoonClient.parseTitleArray(raw, count: 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(out[0]).title.count, 45)
    }

    func testParseTitleArrayDropsOutOfRangeAndEmpty() {
        let raw = #"[{"i":0,"title":"","description":"x"},{"i":9,"title":"Buiten bereik","description":"y"}]"#
        let out = RoonClient.parseTitleArray(raw, count: 2)
        XCTAssertTrue(out.isEmpty, "empty title dropped; index 9 out of range for count 2")
    }

    func testParseTitleArrayGarbageIsEmpty() {
        XCTAssertTrue(RoonClient.parseTitleArray("geen json", count: 3).isEmpty)
    }

    func testParseFallsBackPerMissingField() {
        let (t, d) = RoonClient.parseTitleJSON(
            #"{"title": "  "}"#, fallbackTitle: "FB", fallbackDesc: "FBD")
        XCTAssertEqual(t, "FB", "blank title → fallback")
        XCTAssertEqual(d, "FBD", "missing description → fallback")
    }

    func testParseClampsLongTitleOnWordBoundary() {
        let full = "Dromerige Progressieve Rock van David Gilmour en Pink Floyd"
        let raw = #"{"title": "\#(full)", "description": "ok"}"#
        let (t, _) = RoonClient.parseTitleJSON(raw, fallbackTitle: "FB", fallbackDesc: "FBD")
        XCTAssertLessThanOrEqual(t.count, 45, "long title clamped to max")
        XCTAssertFalse(t.hasSuffix(" "), "no dangling space")
        // The result must be whole leading words of the original (boundary cut).
        XCTAssertTrue(full.hasPrefix(t), "clamped title is a prefix of the original")
        let nextIndex = full.index(full.startIndex, offsetBy: t.count)
        XCTAssertEqual(full[nextIndex], " ", "the character after the cut is a space — no mid-word slice")
    }

    func testClampTitleTrimsTrailingConnector() {
        // Cutting right after "&" must not leave a dangling connector.
        let clamped = RoonClient.clampTitle("Hypnotische Deep House van Bob Moses & friends here", max: 40)
        XCTAssertLessThanOrEqual(clamped.count, 40)
        XCTAssertFalse(clamped.hasSuffix("&"))
        XCTAssertFalse(clamped.hasSuffix(" "))
    }

    func testClampTitleLeavesShortTitleUntouched() {
        XCTAssertEqual(RoonClient.clampTitle("Epische Arena-Rock", max: 45), "Epische Arena-Rock")
    }

    // MARK: stable Qobuz name

    func testQobuzPlaylistNameIsStablePrefix() {
        XCTAssertEqual(RoonClient.qobuzPlaylistName(for: "Gouden Uren"), "RoonSage · Gouden Uren")
    }
}
