@testable import RoonSageCore
import XCTest

/// The explanation-card signature (stable across process launches, order-
/// independent on its list inputs) and the defensive response parser/fallback.
final class DiscoveryExplanationsTests: XCTestCase {

    // MARK: signature

    func testSignatureStableAcrossCalls() {
        let a = DiscoveryExplanations.signature(artist: "Boards of Canada", album: "Geogaddi",
                                                sourceLabels: ["similar-artist-web", "charts"], genres: ["idm", "ambient"])
        let b = DiscoveryExplanations.signature(artist: "Boards of Canada", album: "Geogaddi",
                                                sourceLabels: ["similar-artist-web", "charts"], genres: ["idm", "ambient"])
        XCTAssertEqual(a, b)
    }

    func testSignatureIgnoresListOrder() {
        let a = DiscoveryExplanations.signature(artist: "Autechre", album: nil,
                                                sourceLabels: ["charts", "ai-picks"], genres: ["idm", "electronic"])
        let b = DiscoveryExplanations.signature(artist: "Autechre", album: nil,
                                                sourceLabels: ["ai-picks", "charts"], genres: ["electronic", "idm"])
        XCTAssertEqual(a, b)
    }

    func testSignatureChangesWhenSourcesChange() {
        let a = DiscoveryExplanations.signature(artist: "Squarepusher", album: nil, sourceLabels: ["charts"], genres: [])
        let b = DiscoveryExplanations.signature(artist: "Squarepusher", album: nil,
                                                sourceLabels: ["charts", "gap-fill"], genres: [])
        XCTAssertNotEqual(a, b)
    }

    func testSignatureCaseInsensitive() {
        let a = DiscoveryExplanations.signature(artist: "Squarepusher", album: nil, sourceLabels: ["Charts"], genres: [])
        let b = DiscoveryExplanations.signature(artist: "squarepusher", album: nil, sourceLabels: ["charts"], genres: [])
        XCTAssertEqual(a, b)
    }

    // MARK: parseResponse

    func testParseResponseCleanArray() {
        let raw = #"[{"i":1,"text":"Past bij je smaak voor IDM."},{"i":2,"text":"Vergelijkbaar met Aphex Twin."}]"#
        let parsed = DiscoveryExplanations.parseResponse(raw)
        XCTAssertEqual(parsed[1], "Past bij je smaak voor IDM.")
        XCTAssertEqual(parsed[2], "Vergelijkbaar met Aphex Twin.")
    }

    func testParseResponseFencedAndChatty() {
        let raw = """
        Hier zijn de uitleg:
        ```json
        [{"i":1,"text":"Trending in de charts."}]
        ```
        """
        XCTAssertEqual(DiscoveryExplanations.parseResponse(raw)[1], "Trending in de charts.")
    }

    func testParseResponseDropsEmptyText() {
        let raw = #"[{"i":1,"text":""},{"i":2,"text":"Geldige tekst"}]"#
        let parsed = DiscoveryExplanations.parseResponse(raw)
        XCTAssertNil(parsed[1])
        XCTAssertEqual(parsed[2], "Geldige tekst")
    }

    func testParseResponseGarbageReturnsEmpty() {
        XCTAssertTrue(DiscoveryExplanations.parseResponse("no json here").isEmpty)
    }

    // MARK: fallback

    func testFallbackNeverEmptyAndMentionsGenreWhenPresent() {
        let withGenre = DiscoveryExplanations.fallback(sourceCount: 3, genres: ["ambient"])
        XCTAssertFalse(withGenre.isEmpty)
        XCTAssertTrue(withGenre.lowercased().contains("ambient"))

        let noGenre = DiscoveryExplanations.fallback(sourceCount: 1, genres: [])
        XCTAssertFalse(noGenre.isEmpty)
    }

    // MARK: buildPrompt

    func testBuildPromptIncludesEveryItemIndex() {
        let items = [
            DiscoveryExplanations.Item(index: 1, artist: "A", album: nil, sourceLabels: ["charts"], genres: []),
            DiscoveryExplanations.Item(index: 2, artist: "B", album: "Album B", sourceLabels: ["gap-fill"], genres: ["rock"]),
        ]
        let (_, user) = DiscoveryExplanations.buildPrompt(items)
        XCTAssertTrue(user.contains("1. A"))
        XCTAssertTrue(user.contains("2. B"))
        XCTAssertTrue(user.contains("Album B"))
    }
}
