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

    /// These four shipped to Qobuz verbatim, dangling conjunction and all.
    func testClampTitleTrimsTrailingDutchConjunction() {
        let cases = [
            "Klassiek Instrumentaal: Melancholisch en tijdloos mooi",
            "Elektronische Party: Dansbare beats en stevige drops",
            "R&B Sfeer: Vrolijke zangnummers met warme groove"
        ]
        for c in cases {
            let clamped = RoonClient.clampTitle(c, max: 40)
            let last = clamped.split(separator: " ").last.map(String.init)?.lowercased() ?? ""
            XCTAssertFalse(["en", "met", "of", "van", "voor"].contains(last),
                           "'\(clamped)' ends on a dangling connector")
        }
    }

    func testClampTitlePeelsStackedConnectors() {
        // Two connectors in a row, with punctuation exposed underneath.
        XCTAssertEqual(RoonClient.clampTitle("Zomerse hits, en van de jaren tachtig", max: 22),
                       "Zomerse hits")
    }

    // MARK: trimDangling — repairs titles the length cap can't reach

    /// The four names that actually shipped to Qobuz. All are UNDER the 45-char
    /// cap, so clampTitle is a no-op on them — trimDangling has to stand alone.
    func testTrimDanglingRepairsAlreadyShortCachedTitles() {
        let cases = [
            ("Klassiek Instrumentaal: Melancholisch en", "Klassiek Instrumentaal: Melancholisch"),
            ("Elektronische Party: Dansbare beats en", "Elektronische Party: Dansbare beats"),
            ("Film & Theater: Akoestisch en", "Film & Theater: Akoestisch"),
            ("R&B Sfeer: Vrolijke zangnummers met", "R&B Sfeer: Vrolijke zangnummers")
        ]
        for (broken, want) in cases {
            XCTAssertLessThan(broken.count, 45, "precondition: clampTitle would not touch this")
            XCTAssertEqual(RoonClient.clampTitle(broken, max: 45), broken,
                           "clampTitle alone leaves it broken — that's why trimDangling exists")
            XCTAssertEqual(RoonClient.trimDangling(broken), want)
        }
    }

    func testTrimDanglingLeavesGoodTitleUntouched() {
        XCTAssertEqual(RoonClient.trimDangling("Elektrische Hartslag"), "Elektrische Hartslag")
        XCTAssertEqual(RoonClient.trimDangling("De Stilte tussen Akkoorden"), "De Stilte tussen Akkoorden")
    }

    /// The peel needs a preceding space, so it never eats the last word — a title
    /// is never reduced to nothing by peeling alone. Only pure punctuation can
    /// trim away entirely, which is the case resolveTitle guards against.
    func testTrimDanglingNeverEatsTheLastWord() {
        XCTAssertEqual(RoonClient.trimDangling("en"), "en", "single word has no preceding space")
        XCTAssertEqual(RoonClient.trimDangling("van en"), "van", "peels one, keeps the last")
        XCTAssertEqual(RoonClient.trimDangling("&"), "", "pure punctuation does trim to empty")
    }

    func testClampTitleLeavesShortTitleUntouched() {
        XCTAssertEqual(RoonClient.clampTitle("Epische Arena-Rock", max: 45), "Epische Arena-Rock")
    }

    // MARK: stable Qobuz name

    func testQobuzPlaylistNameIsStablePrefix() {
        XCTAssertEqual(RoonClient.qobuzPlaylistName(for: "Gouden Uren"), "RoonSage · Gouden Uren")
    }

    // MARK: sonicProfileSummary (the measured profile that feeds the AI titles)

    private func sonic(
        _ id: String, bpm: Double? = nil, conf: Double? = nil, camelot: String = "",
        tags: [String] = [], moods: [String: Float] = [:],
        genres: [String] = [], year: Int? = nil
    ) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(
            id: id, title: "T-\(id)", artist: "A", album: nil, imageKey: nil,
            matchKey: "mk-\(id)", bpm: bpm, camelot: camelot, energy: nil,
            tags: tags, moods: moods, bpmConfidence: conf, genres: genres, year: year)
    }

    func testProfilePrefersRealGenresOverLLMTags() {
        let sel = (0..<5).map {
            sonic("\($0)", tags: ["driving", "peak-time"], genres: ["indie rock"])
        }
        let p = RoonClient.sonicProfileSummary(sel)
        XCTAssertTrue(p.contains("genres: indie rock"), p)
        XCTAssertFalse(p.contains("driving"), "LLM tags must not reach the profile when real genres exist: \(p)")
    }

    func testProfileFallsBackToTagsWithoutGenres() {
        let sel = (0..<5).map { sonic("\($0)", tags: ["ambient"]) }
        let p = RoonClient.sonicProfileSummary(sel)
        XCTAssertTrue(p.contains("genres/tags: ambient"), p)
    }

    func testProfileOmitsTempoWhenDetectorUnconfident() {
        let sel = (0..<5).map { sonic("\($0)", bpm: 123, conf: 0.3) }
        XCTAssertFalse(RoonClient.sonicProfileSummary(sel).contains("BPM"),
                       "low-confidence BPM is noise, not measurement")
    }

    func testProfileReportsMedianTempoWhenConfident() {
        let sel = (0..<5).map { sonic("\($0)", bpm: 120 + Double($0), conf: 0.9) }
        XCTAssertTrue(RoonClient.sonicProfileSummary(sel).contains("±122 BPM"))
    }

    func testProfileReportsWideTempoAsSpread() {
        let bpms: [Double] = [70, 95, 120, 150, 180]
        let sel = bpms.enumerated().map { sonic("\($0.offset)", bpm: $0.element, conf: 0.9) }
        let p = RoonClient.sonicProfileSummary(sel)
        XCTAssertTrue(p.contains("tempo wisselt"), p)
    }

    func testProfileCalibratedMoodOverridesTextPrior() {
        // Library-wide, "danceable" scores structurally higher than "sad" (CLAP
        // text prior). The selection is *unusually* sad for this library — the
        // calibrated profile must say melancholisch, not dansbaar.
        let library = (0..<20).map {
            sonic("lib\($0)", moods: ["danceable": 0.38 + Float($0) * 0.004,
                                      "sad": 0.05 + Float($0) * 0.004])
        }
        let cal = TitleGrounding.Calibration.compute(library: library)
        let sel = (0..<5).map {
            sonic("sel\($0)", moods: ["danceable": 0.40, "sad": 0.30 + Float($0) * 0.001])
        }
        let p = RoonClient.sonicProfileSummary(sel, calibration: cal)
        XCTAssertTrue(p.contains("sfeer: melancholisch"), p)
        XCTAssertFalse(p.contains("dansbaar"), p)
    }

    func testProfileReportsDominantKeyMode() {
        let sel = (0..<5).map { sonic("\($0)", camelot: $0 < 4 ? "8A" : "8B") }
        XCTAssertTrue(RoonClient.sonicProfileSummary(sel).contains("overwegend mineur"))
        let major = (0..<5).map { sonic("\($0)", camelot: "8B") }
        XCTAssertTrue(RoonClient.sonicProfileSummary(major).contains("overwegend majeur"))
    }

    func testProfileReportsPeriodFromYears() {
        let sel = (0..<6).map { sonic("\($0)", year: 1980 + $0) }
        let p = RoonClient.sonicProfileSummary(sel)
        XCTAssertTrue(p.contains("periode: 1980–1985"), p)
    }

    func testProfileSkipsPeriodOnSparseYears() {
        let sel = (0..<6).map { sonic("\($0)", year: $0 == 0 ? 1980 : nil) }
        XCTAssertFalse(RoonClient.sonicProfileSummary(sel).contains("periode"),
                       "one year out of six is not a measured period")
    }
}
