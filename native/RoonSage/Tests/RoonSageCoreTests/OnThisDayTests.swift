import XCTest
@testable import RoonSageCore

/// "Op deze dag": plays from today's month-day in earlier years.
final class OnThisDayTests: XCTestCase {
    private var dbURL: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-otd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("library.db")
        db = try DatabaseManager(url: dbURL)
    }

    override func tearDownWithError() throws {
        db = nil
        if let dir = dbURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func listen(_ title: String, _ artist: String, at playedAt: String) -> DatabaseManager.ImportedListen {
        DatabaseManager.ImportedListen(title: title, artist: artist, album: nil, playedAt: playedAt)
    }

    func testReturnsSameMonthDayPriorYearsNewestFirst() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-07-07T10:00:00Z")!
        try await db.appendImportedListens([
            listen("A", "ArtA", at: "2024-07-07T08:00:00Z"),   // match, 2024
            listen("B", "ArtB", at: "2023-07-07T20:00:00Z"),   // match, 2023
            listen("C", "ArtC", at: "2025-07-08T08:00:00Z"),   // wrong day
            listen("D", "ArtD", at: "2026-07-07T08:00:00Z"),   // this year → excluded
            listen("E", "ArtE", at: "2022-12-25T08:00:00Z"),   // wrong day
        ], source: "test", zoneName: "Test")

        let entries = try await db.onThisDay(now: now)
        XCTAssertEqual(entries.map { $0.title }, ["A", "B"], "only same MM-DD prior years, newest play first")
        XCTAssertEqual(entries.first?.year, 2024)
        XCTAssertEqual(entries.last?.year, 2023)
    }

    func testExcludesCurrentYearAndRespectsLimit() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-03-15T10:00:00Z")!
        try await db.appendImportedListens([
            listen("x1", "a", at: "2020-03-15T01:00:00Z"),
            listen("x2", "a", at: "2021-03-15T02:00:00Z"),
            listen("x3", "a", at: "2022-03-15T03:00:00Z"),
            listen("cur", "a", at: "2026-03-15T09:00:00Z"),   // current year → never
        ], source: "test", zoneName: "T")

        let limited = try await db.onThisDay(now: now, limit: 2)
        XCTAssertEqual(limited.map { $0.year }, [2022, 2021], "newest years first, capped to the limit")
        XCTAssertFalse(limited.contains { $0.title == "cur" }, "current year is excluded")
    }

    /// Guards the thin-client fetch: the real /on-this-day JSON must decode into
    /// the shared struct (captured verbatim from the live server).
    func testDecodesLiveServerJSON() throws {
        let json = Data("""
        [{"year":2025,"playedAt":"2025-07-07T18:07:40Z","title":"Postcards from Paraguay","album":"Mark Knopfler Live at Amsterdam","artist":"Mark Knopfler"}]
        """.utf8)
        let entries = try JSONDecoder().decode([DatabaseManager.OnThisDayEntry].self, from: json)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].year, 2025)
        XCTAssertEqual(entries[0].artist, "Mark Knopfler")
        XCTAssertEqual(entries[0].title, "Postcards from Paraguay")
    }

    func testEmptyWhenNothingMatches() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-01-01T10:00:00Z")!
        try await db.appendImportedListens([
            listen("z", "a", at: "2024-06-30T08:00:00Z"),
        ], source: "test", zoneName: "T")
        let entries = try await db.onThisDay(now: now)
        XCTAssertTrue(entries.isEmpty)
    }
}
