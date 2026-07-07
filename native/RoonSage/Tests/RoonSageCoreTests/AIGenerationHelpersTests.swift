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
}
