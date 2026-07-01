@testable import RoonSageCore
import XCTest

/// Pure weekly-digest selection (F12b): dedupe-by-highest-score, the limit cap,
/// deterministic tie-breaking, and the ISO week key's year boundary handling.
final class DigestSelectionTests: XCTestCase {

    private func c(_ key: String, _ album: String, _ score: Double) -> DigestSelection.Candidate {
        .init(dedupKey: key, artist: "Artist", album: album, qobuzAlbumID: "q-\(key)", score: score)
    }

    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents(); comps.year = y; comps.month = m; comps.day = d
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)!
    }

    // MARK: top()

    func testRanksByScoreDescending() {
        let result = DigestSelection.top([c("a", "A", 0.5), c("b", "B", 0.9), c("c", "C", 0.3)], limit: 10)
        XCTAssertEqual(result.map(\.album), ["B", "A", "C"])
    }

    func testDedupeKeepsHighestScoringOccurrence() {
        // Same album (same dedupKey) surfaced in two retained batches at
        // different scores — only the best one should survive.
        let result = DigestSelection.top([c("x", "Same Album", 0.4), c("x", "Same Album", 0.8)], limit: 10)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.score, 0.8)
    }

    func testLimitCaps() {
        let candidates = (0..<10).map { c("k\($0)", "Album\($0)", Double($0)) }
        XCTAssertEqual(DigestSelection.top(candidates, limit: 3).count, 3)
        // Highest 3 scores (9, 8, 7) survive.
        XCTAssertEqual(DigestSelection.top(candidates, limit: 3).map(\.album), ["Album9", "Album8", "Album7"])
    }

    func testTiesBreakAlphabeticallyByAlbum() {
        let result = DigestSelection.top([c("a", "Zebra", 0.5), c("b", "Apple", 0.5)], limit: 10)
        XCTAssertEqual(result.map(\.album), ["Apple", "Zebra"])
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(DigestSelection.top([], limit: 10).count, 0)
    }

    func testZeroLimitReturnsEmpty() {
        XCTAssertEqual(DigestSelection.top([c("a", "A", 1.0)], limit: 0).count, 0)
    }

    // MARK: weekKey(for:)

    func testWeekKeyMidYear() {
        // 2026-07-01 is a Wednesday in ISO week 27.
        XCTAssertEqual(DigestSelection.weekKey(for: utc(2026, 7, 1)), "2026-W27")
    }

    func testWeekKeyEarlyJanuaryBelongsToPriorISOYear() {
        // 2027-01-01 is a Friday — ISO week 53 of 2026, NOT week 1 of 2027.
        XCTAssertEqual(DigestSelection.weekKey(for: utc(2027, 1, 1)), "2026-W53")
    }

    func testWeekKeyLateDecemberBelongsToNextISOYear() {
        // 2025-12-29 is a Monday — ISO week 1 of 2026, NOT week 52 of 2025.
        XCTAssertEqual(DigestSelection.weekKey(for: utc(2025, 12, 29)), "2026-W01")
    }
}
