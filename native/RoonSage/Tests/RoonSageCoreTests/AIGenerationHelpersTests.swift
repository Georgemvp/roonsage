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
