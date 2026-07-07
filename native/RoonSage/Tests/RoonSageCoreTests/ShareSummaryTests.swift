import XCTest
@testable import RoonSageCore

final class ShareSummaryTests: XCTestCase {

    private func entry(_ title: String, _ artist: String?, _ year: Int) -> DatabaseManager.OnThisDayEntry {
        DatabaseManager.OnThisDayEntry(year: year, title: title, artist: artist, album: nil, playedAt: "")
    }
    private func period(_ year: Int, _ artists: [(String, Int)]) -> DatabaseManager.TastePeriod {
        DatabaseManager.TastePeriod(
            year: year, totalPlays: artists.reduce(0) { $0 + $1.1 },
            topArtists: artists.map { DatabaseManager.ArtistPlayCount(artist: $0.0, count: $0.1) })
    }

    func testOnThisDaySummaryLinesAndCap() {
        let text = ShareSummary.onThisDay([
            entry("Postcards from Paraguay", "Mark Knopfler", 2025),
            entry("Sultans of Swing", "Dire Straits", 2023),
            entry("Xtal", nil, 2022),
        ], max: 2)
        XCTAssertTrue(text.contains("🎵 Op deze dag"))
        XCTAssertTrue(text.contains("• Postcards from Paraguay — Mark Knopfler (2025)"))
        XCTAssertTrue(text.contains("• Sultans of Swing — Dire Straits (2023)"))
        XCTAssertFalse(text.contains("Xtal"), "respects the max cap")
        XCTAssertTrue(text.contains(ShareSummary.signature))
    }

    func testNilArtistFallsBack() {
        let text = ShareSummary.onThisDay([entry("Xtal", nil, 2022)])
        XCTAssertTrue(text.contains("• Xtal — Onbekend (2022)"))
    }

    func testTimeMachineSummaryPerYear() {
        let text = ShareSummary.tasteTimeMachine([
            period(2026, [("Dire Straits", 274), ("Mark Knopfler", 219), ("John Illsley", 120), ("Supertramp", 94)]),
            period(2025, [("Dire Straits", 656)]),
        ], maxYears: 5, artistsPerYear: 3)
        XCTAssertTrue(text.contains("⏳ Mijn muziek-tijdmachine"))
        XCTAssertTrue(text.contains("2026: Dire Straits, Mark Knopfler, John Illsley"))
        XCTAssertFalse(text.contains("Supertramp"), "caps at artistsPerYear")
        XCTAssertTrue(text.contains("2025: Dire Straits"))
    }

    func testEmptyInputsYieldEmptyString() {
        XCTAssertEqual(ShareSummary.onThisDay([]), "")
        XCTAssertEqual(ShareSummary.tasteTimeMachine([]), "")
    }
}
