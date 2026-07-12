@testable import RoonSageCore
import XCTest

/// The pure, model-independent helpers underpinning AI playlist generation:
/// number parsing, decade parsing, scope summaries, reasoning stripping, and the
/// status-aware (Dutch) LLM error copy.
final class AIGenerationHelpersTests: XCTestCase {

    // MARK: PlaylistAssembler.picks

    func testPicksParsesCommaSeparatedNumbers() {
        XCTAssertEqual(PlaylistAssembler.picks(from: "3, 17, 42, 8", max: 100), [3, 17, 42, 8])
    }

    func testPicksKeepsOnlyInRangeAndPreservesOrder() {
        // 0 and out-of-range 99 dropped; order preserved; mixed separators handled.
        XCTAssertEqual(PlaylistAssembler.picks(from: "5\n2; 0 99 4", max: 10), [5, 2, 4])
    }

    func testPicksStripsReasoningBlock() {
        let raw = "<think>I should pick variety</think>\n1, 2, 3"
        XCTAssertEqual(PlaylistAssembler.picks(from: raw, max: 10), [1, 2, 3])
    }

    func testPicksEmptyOnGarbage() {
        XCTAssertEqual(PlaylistAssembler.picks(from: "no numbers here", max: 10), [])
    }

    // MARK: RoonClient.parseDecades

    func testParseDecadesHandlesIntDoubleAndString() {
        // Int, Double (the case Int(String(describing:)) silently dropped), string.
        XCTAssertEqual(RoonClient.parseDecades([1980, 1990.0, "2000"]), [1980, 1990, 2000])
    }

    func testParseDecadesFloorsToBoundaryAndDedups() {
        XCTAssertEqual(RoonClient.parseDecades([1987, 1983]), [1980])
    }

    func testParseDecadesRejectsOutOfRange() {
        XCTAssertEqual(RoonClient.parseDecades([1850, 3000, 1975]), [1970])
        XCTAssertEqual(RoonClient.parseDecades("not an array"), [])
    }

    // MARK: RequestFilters.scopeSummary

    func testScopeSummaryListsGenresTagsDecades() {
        let f = RoonClient.RequestFilters(genres: ["Jazz"], decades: [1970], keywords: "", tags: ["chill"])
        XCTAssertEqual(f.scopeSummary(poolSize: 240), "Uit Jazz · chill · 1970s (240 kandidaten)")
    }

    func testScopeSummaryWholeLibraryWhenEmpty() {
        XCTAssertEqual(RoonClient.RequestFilters().scopeSummary(poolSize: 12),
                       "Uit hele bibliotheek (12 kandidaten)")
    }

    func testRequestFiltersIsEmpty() {
        XCTAssertTrue(RoonClient.RequestFilters().isEmpty)
        XCTAssertFalse(RoonClient.RequestFilters(tags: ["x"]).isEmpty)
        XCTAssertFalse(RoonClient.RequestFilters(moods: ["relaxed"]).isEmpty)
        XCTAssertFalse(RoonClient.RequestFilters(activities: ["focus"]).isEmpty)
    }

    func testScopeSummaryTranslatesMoodsAndActivities() {
        let f = RoonClient.RequestFilters(moods: ["relaxed"], activities: ["workout"])
        XCTAssertEqual(f.scopeSummary(poolSize: 9), "Uit Ontspannen · Workout (9 kandidaten)")
    }

    // MARK: Generate — measured request gate (M2)

    private func sonic(_ id: String, moods: [String: Float] = [:], bpm: Double? = nil,
                       energy: Double? = nil, attributes: [String: Float] = [:]) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(id: id, title: id, artist: "A", album: nil, imageKey: nil,
                                   matchKey: id, bpm: bpm, camelot: "8B", energy: energy, tags: [],
                                   moods: moods, attributes: attributes)
    }

    func testRequestGateNilWithoutFacets() {
        XCTAssertNil(RoonClient.requestGate(moods: [], activities: [], calibration: nil))
    }

    func testRequestGateMatchesDominantOrThresholdMood() {
        let gate = RoonClient.requestGate(moods: ["relaxed"], activities: [], calibration: nil)!
        XCTAssertTrue(gate(sonic("dominant", moods: ["relaxed": 0.2, "sad": 0.1])),
                      "dominant mood matches even under the absolute threshold")
        XCTAssertTrue(gate(sonic("threshold", moods: ["happy": 0.6, "relaxed": 0.4])),
                      "non-dominant mood ≥ 0.3 still matches")
        XCTAssertFalse(gate(sonic("neither", moods: ["happy": 0.6, "relaxed": 0.1])))
        XCTAssertFalse(gate(sonic("unanalyzed")), "no moods at all → no match")
    }

    func testRequestGateAppliesActivityProfile() {
        // Workout: energy percentile ≥ 0.70 && bpm ≥ 120 (uncalibrated: raw signal).
        let gate = RoonClient.requestGate(moods: [], activities: ["workout"], calibration: nil)!
        XCTAssertTrue(gate(sonic("banger", bpm: 140, energy: 0.9)))
        XCTAssertFalse(gate(sonic("ballad", bpm: 70, energy: 0.2)))
    }

    // MARK: Generate — flow ordering (QW1)

    func testFlowOrderKeepsAllTracksIncludingUnanalyzed() {
        let recs = [TrackRecord(id: "r1", title: "T1", artist: "A", matchKey: "k1"),
                    TrackRecord(id: "r2", title: "T2", artist: "B", matchKey: nil),   // unanalyzed
                    TrackRecord(id: "r3", title: "T3", artist: "C", matchKey: "k3"),
                    TrackRecord(id: "r4", title: "T4", artist: "D", matchKey: "k4")]
        let byKey = ["k1": sonic("s1", bpm: 100, energy: 0.4),
                     "k3": sonic("s3", bpm: 104, energy: 0.5),
                     "k4": sonic("s4", bpm: 160, energy: 0.9)]
        let out = RoonClient.flowOrder(recs, byKey: byKey, arc: .smooth)
        XCTAssertEqual(Set(out.map(\.id)), Set(recs.map(\.id)), "nothing dropped or duplicated")
        XCTAssertEqual(out.count, recs.count)
    }

    func testFlowOrderIsDeterministic() {
        let recs = (0..<6).map { TrackRecord(id: "r\($0)", title: "T\($0)", artist: "A\($0)", matchKey: "k\($0)") }
        let byKey = Dictionary(uniqueKeysWithValues: (0..<6).map {
            ("k\($0)", sonic("s\($0)", bpm: 90 + Double($0) * 10, energy: Double($0) / 6))
        })
        XCTAssertEqual(RoonClient.flowOrder(recs, byKey: byKey, arc: .peak).map(\.id),
                       RoonClient.flowOrder(recs, byKey: byKey, arc: .peak).map(\.id))
    }

    // MARK: Generate — duration target (U3)

    func testTrimToDurationKeepsBestPrefix() {
        let recs = (0..<6).map { TrackRecord(id: "r\($0)", title: "T\($0)", matchKey: "k\($0)") }
        let byKey = Dictionary(uniqueKeysWithValues: (0..<6).map { ("k\($0)", 300.0) })  // 5 min each
        // Budget 16 min: 3 tracks = 15 min (under by 1), 4 = 20 (over by 4) → keep 3.
        let out = RoonClient.trimToDuration(recs, budgetSeconds: 16 * 60, durationByKey: byKey)
        XCTAssertEqual(out.map(\.id), ["r0", "r1", "r2"])
    }

    func testTrimToDurationIncludesCrossingTrackWhenCloser() {
        let recs = (0..<4).map { TrackRecord(id: "r\($0)", title: "T\($0)", matchKey: "k\($0)") }
        let byKey = Dictionary(uniqueKeysWithValues: (0..<4).map { ("k\($0)", 300.0) })
        // Budget 14 min: 2 tracks = 10 (under 4), 3 = 15 (over 1) → 15 is closer, keep 3.
        let out = RoonClient.trimToDuration(recs, budgetSeconds: 14 * 60, durationByKey: byKey)
        XCTAssertEqual(out.map(\.id), ["r0", "r1", "r2"])
    }

    func testTrimToDurationAlwaysKeepsAtLeastOne() {
        let recs = [TrackRecord(id: "r0", title: "Long", matchKey: "k0")]
        let out = RoonClient.trimToDuration(recs, budgetSeconds: 60, durationByKey: ["k0": 600])
        XCTAssertEqual(out.map(\.id), ["r0"], "a single over-budget track is still returned")
    }

    func testTrimToDurationUsesAverageForUnknown() {
        // No durations known → 3.5-min average per track; budget 8 min keeps 2 (7 min).
        let recs = (0..<5).map { TrackRecord(id: "r\($0)", title: "T\($0)", matchKey: "k\($0)") }
        let out = RoonClient.trimToDuration(recs, budgetSeconds: 8 * 60, durationByKey: [:])
        XCTAssertEqual(out.count, 2)
    }

    // MARK: Generate — request-derived arc (M3)

    func testSuggestedArcFromActivity() {
        XCTAssertEqual(RoonClient.suggestedArc(for: .init(activities: ["workout"])), .peak)
        XCTAssertEqual(RoonClient.suggestedArc(for: .init(activities: ["focus"])), .smooth)
        XCTAssertEqual(RoonClient.suggestedArc(for: .init(activities: ["onderweg"])), .gentleRise)
    }

    func testSuggestedArcFromMoodAndDefault() {
        XCTAssertEqual(RoonClient.suggestedArc(for: .init(moods: ["relaxed"])), .smooth)
        XCTAssertEqual(RoonClient.suggestedArc(for: .init(moods: ["party"])), .peak)
        XCTAssertEqual(RoonClient.suggestedArc(for: .init()), .peak, "no facets → default peak journey")
    }

    func testSuggestedArcActivityBeatsMood() {
        // Activity is the stronger structural signal: focus stays smooth even if a
        // party mood also leaked in.
        XCTAssertEqual(RoonClient.suggestedArc(for: .init(moods: ["party"], activities: ["focus"])), .smooth)
    }

    // MARK: Generate — server-side wire contract (POST /generate)

    func testArcWireRoundTrips() {
        for arc in [RadioSequencer.Arc.smooth, .gentleRise, .peak] {
            XCTAssertEqual(RoonClient.arc(fromWire: RoonClient.arcWireKey(arc)), arc)
        }
        XCTAssertNil(RoonClient.arc(fromWire: nil), "nil wire key = auto arc")
        XCTAssertNil(RoonClient.arc(fromWire: "bogus"))
    }

    func testGenerateRequestDTORoundTrips() throws {
        let dto = RoonClient.GenerateRequestDTO(
            request: "chill jazz", target: 20, adventurousness: 0.4, arc: "peak",
            targetMinutes: 60, seedArtists: ["Bill Evans"], seedTrackKeys: ["k1", "k2"])
        let back = try JSONDecoder().decode(RoonClient.GenerateRequestDTO.self,
                                            from: JSONEncoder().encode(dto))
        XCTAssertEqual(back.request, "chill jazz")
        XCTAssertEqual(back.target, 20)
        XCTAssertEqual(back.arc, "peak")
        XCTAssertEqual(back.targetMinutes, 60)
        XCTAssertEqual(back.seedArtists, ["Bill Evans"])
        XCTAssertEqual(back.seedTrackKeys, ["k1", "k2"])
    }

    func testGenerationResultRoundTripsOverTheWire() throws {
        let result = RoonClient.GenerationResult(
            tracks: [TrackRecord(id: "r1", title: "T1", artist: "A", matchKey: "k1")],
            filters: RoonClient.RequestFilters(genres: ["Jazz"], moods: ["relaxed"]),
            poolSize: 172, title: "Regen op het raam", description: "Rustige jazz.",
            droppedNote: nil, aiCurated: true,
            fallbackNote: "Sonische rangschikking niet beschikbaar.",
            reasonByTrackID: ["r1": "Sluit aan bij je verzoek"],
            trace: "╭── AI-playlist generatie ──")
        let back = try JSONDecoder().decode(RoonClient.GenerationResult.self,
                                            from: JSONEncoder().encode(result))
        XCTAssertEqual(back.tracks.map(\.id), ["r1"])
        XCTAssertEqual(back.filters.genres, ["Jazz"])
        XCTAssertEqual(back.filters.moods, ["relaxed"])
        XCTAssertEqual(back.poolSize, 172)
        XCTAssertEqual(back.title, "Regen op het raam")
        XCTAssertTrue(back.aiCurated)
        XCTAssertEqual(back.fallbackNote, "Sonische rangschikking niet beschikbaar.")
        XCTAssertEqual(back.reasonByTrackID["r1"], "Sluit aan bij je verzoek")
        XCTAssertEqual(back.trace, "╭── AI-playlist generatie ──")
    }

    func testGenerationResultDecodesLegacyPayloadWithoutFallbackNote() throws {
        // A payload from an older server (predating fallbackNote) must still
        // decode on a newer client — the field is optional on the wire.
        let result = RoonClient.GenerationResult(
            tracks: [TrackRecord(id: "r1", title: "T1", artist: "A", matchKey: "k1")],
            filters: RoonClient.RequestFilters(genres: ["Jazz"]),
            poolSize: 10, title: "T", description: nil,
            droppedNote: nil, aiCurated: true)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(result)) as? [String: Any])
        obj.removeValue(forKey: "fallbackNote")
        let back = try JSONDecoder().decode(
            RoonClient.GenerationResult.self,
            from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(back.fallbackNote)
        XCTAssertEqual(back.tracks.map(\.id), ["r1"])
    }

    // MARK: Generate — diagnostic trace

    func testGenerationTraceListCapsAndMarksOverflow() {
        XCTAssertEqual(GenerationTrace.list([]), "—")
        XCTAssertEqual(GenerationTrace.list(["a", "b"]), "a, b")
        let many = (1...15).map { "x\($0)" }
        XCTAssertEqual(GenerationTrace.list(many, cap: 3), "x1, x2, x3 … (+12)")
    }

    func testGenerationTraceRendersSectionsAndLines() {
        let t = GenerationTrace()
        t.section("Verzoek")
        t.kv("prompt", "“chill jazz”")
        t.kvIf("leeg", "")          // skipped
        t.kvIf("wel", "x")
        let out = t.render()
        XCTAssertTrue(out.contains("Verzoek"), out)
        XCTAssertTrue(out.contains("prompt: “chill jazz”"), out)
        XCTAssertFalse(out.contains("leeg:"), "empty kvIf is omitted")
        XCTAssertTrue(out.contains("wel: x"), out)
    }

    func testArcLabel() {
        XCTAssertEqual(RoonClient.arcLabel(.smooth), "vloeiend")
        XCTAssertEqual(RoonClient.arcLabel(.gentleRise), "oplopend")
        XCTAssertEqual(RoonClient.arcLabel(.peak), "piek")
    }

    // MARK: Generate — reason copy

    func testReasonTextRewordsSimilarForRequests() {
        XCTAssertEqual(RoonClient.reasonText(.init(kind: .similar, detail: "X")),
                       "Sluit aan bij je verzoek")
        XCTAssertEqual(RoonClient.reasonText(.init(kind: .favorite, detail: "Nick Cave")),
                       "Omdat je Nick Cave mooi vond")
    }

    // MARK: LLMClient.stripReasoning

    func testStripReasoningRemovesVariants() {
        XCTAssertEqual(LLMClient.stripReasoning("<think>a</think>OK"), "OK")
        XCTAssertEqual(LLMClient.stripReasoning("<THINKING>x\ny</THINKING>\n{\"a\":1}"), "{\"a\":1}")
        XCTAssertEqual(LLMClient.stripReasoning("<reasoning>r</reasoning> done"), "done")
    }

    func testStripReasoningHandlesUnterminatedTag() {
        XCTAssertEqual(LLMClient.stripReasoning("answer<think>still thinking with no close"), "answer")
    }

    // MARK: LLMError copy (Dutch + actionable)

    func testLLMErrorMessagesAreDutch() {
        XCTAssertEqual(LLMError.unauthorized.errorDescription,
                       "Ongeldige of ontbrekende API-sleutel — controleer deze bij Instellingen → LLM.")
        XCTAssertEqual(LLMError.rateLimited.errorDescription,
                       "Te veel verzoeken naar de AI — wacht even en probeer het opnieuw.")
        XCTAssertTrue(LLMError.serverError(code: 503, message: nil).errorDescription?.contains("503") ?? false)
        XCTAssertTrue(LLMError.providerError("model not found").errorDescription?.contains("model not found") ?? false)
    }

    // MARK: extractAPIError

    func testExtractAPIErrorOpenAIShape() {
        let body = Data(#"{"error":{"message":"Incorrect API key"}}"#.utf8)
        XCTAssertEqual(LLMClient.extractAPIError(from: body), "Incorrect API key")
    }

    func testExtractAPIErrorOllamaFlatShape() {
        let body = Data(#"{"error":"model 'foo' not found"}"#.utf8)
        XCTAssertEqual(LLMClient.extractAPIError(from: body), "model 'foo' not found")
    }

    // MARK: LLMConfig defaults

    func testEffectiveModelFallsBackToProviderDefault() {
        XCTAssertEqual(LLMConfig(provider: .gemini, model: "").effectiveModel, "gemini-2.5-flash")
        XCTAssertEqual(LLMConfig(provider: .openai, model: " ").effectiveModel, "gpt-4.1-mini")
        XCTAssertEqual(LLMConfig(provider: .ollama, model: "custom:1b").effectiveModel, "custom:1b")
    }

    // MARK: DatabaseManager.genreFamily

    func testGenreFamilyFoldsSubgenresIntoJazz() {
        // "smooth"/"contemporary"/"vocal jazz" must land in jazz, not easy-listening.
        XCTAssertEqual(DatabaseManager.genreFamily("Smooth Jazz"), "jazz")
        XCTAssertEqual(DatabaseManager.genreFamily("contemporary jazz"), "jazz")
        XCTAssertEqual(DatabaseManager.genreFamily("vocal jazz"), "jazz")
    }

    func testGenreFamilyGroupsElectronicDanceTags() {
        for tag in ["House", "electro", "french house", "progressive house", "dance", "techno"] {
            XCTAssertEqual(DatabaseManager.genreFamily(tag), "electronic", "\(tag) → electronic")
        }
    }

    func testGenreFamilyUnknownTagIsItsOwnFamily() {
        XCTAssertEqual(DatabaseManager.genreFamily("Stage & Screen"), "stage & screen")
    }

    // MARK: DatabaseManager.passesGenrePurity — real library genre profiles

    func testPurityKeepsRealJazzConfirmedBySboth() {
        // Jay Beckenstein / Boney James: jazz in Roon AND MB → confirmed.
        XCTAssertTrue(DatabaseManager.passesGenrePurity(
            roon: ["Jazz"], mb: ["jazz", "smooth jazz"], requested: ["jazz"]))
        XCTAssertTrue(DatabaseManager.passesGenrePurity(
            roon: ["Jazz"], mb: ["jazz"], requested: ["jazz"]))
    }

    func testPurityKeepsSingleSourceJazzWhenFamilyDominant() {
        // Dave Koz "Christmas Waltz": no Roon genre, MB all jazz-family → plurality.
        XCTAssertTrue(DatabaseManager.passesGenrePurity(
            roon: [], mb: ["contemporary jazz", "jazz", "smooth jazz"], requested: ["jazz"]))
    }

    func testPurityDropsSpuriousJazzTagOnElectronicTrack() {
        // Bob Moses "Here We Are": lone MB "jazz" among electronic/house → dropped.
        XCTAssertFalse(DatabaseManager.passesGenrePurity(
            roon: ["Electronic", "Pop/Rock"], mb: ["electronic", "house", "jazz"], requested: ["jazz"]))
        // Daft Punk "Nightvision": lone Roon "Jazz" against 6 electronic MB tags.
        XCTAssertFalse(DatabaseManager.passesGenrePurity(
            roon: ["Electronic", "Jazz", "Pop/Rock"],
            mb: ["dance", "electro", "electronic", "french house", "house", "progressive house"],
            requested: ["jazz"]))
    }

    func testPurityDropsOffGenreWhereOtherFamilyDominates() {
        // Chet Atkins country instrumental with a minority MB "jazz" tag → dropped.
        XCTAssertFalse(DatabaseManager.passesGenrePurity(
            roon: ["Country", "Country"],
            mb: ["classical", "country", "country pop", "easy listening", "folk", "jazz"],
            requested: ["jazz"]))
    }

    func testPurityLenientWhenNoGenreData() {
        // No tags at all → don't penalise (stay in the pool).
        XCTAssertTrue(DatabaseManager.passesGenrePurity(roon: [], mb: [], requested: ["jazz"]))
    }
}
