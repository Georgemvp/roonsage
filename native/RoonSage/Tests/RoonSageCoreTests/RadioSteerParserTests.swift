import XCTest
@testable import RoonSageCore

/// Natural-language radio steering → adventurousness-dial delta.
final class RadioSteerParserTests: XCTestCase {
    private func delta(_ phrase: String) -> Double? {
        RadioSteerParser.parse(phrase)?.adventurousnessDelta
    }

    func testAdventurousPhrasesPushUp() {
        XCTAssertEqual(delta("maak het avontuurlijker"), RadioSteerParser.step)
        XCTAssertEqual(delta("verras me"), RadioSteerParser.step)
        XCTAssertEqual(delta("surprise me"), RadioSteerParser.step)
        XCTAssertEqual(delta("iets wilder graag"), RadioSteerParser.step)
    }

    func testSafePhrasesPushDown() {
        XCTAssertEqual(delta("hou het veiliger"), -RadioSteerParser.step)
        XCTAssertEqual(delta("iets vertrouwder"), -RadioSteerParser.step)
        XCTAssertEqual(delta("familiar please"), -RadioSteerParser.step)
    }

    func testNegationFlipsAnUpWordToDown() {
        // Substring "verras" is present, but the negation must win.
        XCTAssertEqual(delta("minder verrassing"), -RadioSteerParser.step)
        XCTAssertEqual(delta("niet zo avontuurlijk"), -RadioSteerParser.step)
        XCTAssertEqual(delta("less adventurous"), -RadioSteerParser.step)
    }

    func testIntensifierMakesTheStepLarger() {
        XCTAssertEqual(delta("veel avontuurlijker"), RadioSteerParser.strongStep)
        XCTAssertEqual(delta("heel veel minder verrassing"), -RadioSteerParser.strongStep)
    }

    func testUnrecognisedOrEnergyPhrasesReturnNil() {
        XCTAssertNil(delta(""))
        XCTAssertNil(delta("speel iets rustigs"))   // energy, not adventurousness — no mis-map
        XCTAssertNil(delta("volgende nummer"))
    }
}
