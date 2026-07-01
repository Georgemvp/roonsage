@testable import RoonSageCore
import XCTest

/// The defensive JSON-array extractor for the AI-picks producer — must survive
/// a chatty/fenced LLM reply the same way `firstJSONObject` does for objects.
final class AIPicksParseTests: XCTestCase {

    func testCleanArrayParses() {
        let raw = #"[{"artist":"Boards of Canada","album":null,"confidence":0.8}]"#
        let picks = AIPicksProducer.parsePicks(raw)
        XCTAssertEqual(picks.count, 1)
        XCTAssertEqual(picks[0].artist, "Boards of Canada")
        XCTAssertNil(picks[0].album)
        XCTAssertEqual(picks[0].confidence, 0.8, accuracy: 1e-9)
    }

    func testFencedAndChattyReplyStillParses() {
        let raw = """
        Sure! Here are some picks:
        ```json
        [{"artist":"Aphex Twin","album":"Selected Ambient Works 85-92","confidence":0.9}]
        ```
        Hope that helps!
        """
        let picks = AIPicksProducer.parsePicks(raw)
        XCTAssertEqual(picks.count, 1)
        XCTAssertEqual(picks[0].artist, "Aphex Twin")
        XCTAssertEqual(picks[0].album, "Selected Ambient Works 85-92")
    }

    func testMissingConfidenceDefaultsToNeutral() {
        let raw = #"[{"artist":"Autechre"}]"#
        let picks = AIPicksProducer.parsePicks(raw)
        XCTAssertEqual(picks.count, 1)
        XCTAssertEqual(picks[0].confidence, 0.5, accuracy: 1e-9)
    }

    func testStringConfidenceCoerced() {
        let raw = #"[{"artist":"Squarepusher","confidence":"0.7"}]"#
        XCTAssertEqual(AIPicksProducer.parsePicks(raw).first?.confidence ?? 0, 0.7, accuracy: 1e-9)
    }

    func testEntryWithoutArtistDropped() {
        let raw = #"[{"album":"No Artist Here"},{"artist":"Real Artist"}]"#
        let picks = AIPicksProducer.parsePicks(raw)
        XCTAssertEqual(picks.count, 1)
        XCTAssertEqual(picks[0].artist, "Real Artist")
    }

    func testGarbageReturnsEmpty() {
        XCTAssertTrue(AIPicksProducer.parsePicks("not json at all").isEmpty)
        XCTAssertTrue(AIPicksProducer.parsePicks("").isEmpty)
    }
}
