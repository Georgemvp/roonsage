import XCTest
@testable import RoonSageCore

/// "Taste time machine": top artists per calendar year from listening_history.
final class TasteTimeMachineTests: XCTestCase {
    private var dbURL: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-ttm-\(UUID().uuidString)", isDirectory: true)
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

    /// `n` plays of `artist` in `year`, at distinct instants so counts are exact
    /// and no dedup collapses them.
    private func plays(_ artist: String, _ year: Int, _ n: Int) -> [DatabaseManager.ImportedListen] {
        (0..<n).map { i in
            DatabaseManager.ImportedListen(
                title: "\(artist)-\(i)", artist: artist, album: nil,
                playedAt: String(format: "%04d-06-15T%02d:00:00Z", year, i % 24))
        }
    }

    func testTopArtistsPerYearNewestYearFirst() async throws {
        var seed: [DatabaseManager.ImportedListen] = []
        seed += plays("Alpha", 2024, 5)   // 2024 winner
        seed += plays("Beta",  2024, 2)
        seed += plays("Gamma", 2023, 4)   // 2023 winner
        seed += plays("Delta", 2023, 1)
        try await db.appendImportedListens(seed, source: "test", zoneName: "T")

        let periods = try await db.tasteTimeMachine(topPerYear: 5)
        XCTAssertEqual(periods.map { $0.year }, [2024, 2023], "newest year first")
        XCTAssertEqual(periods.first?.topArtists.first?.artist, "Alpha")
        XCTAssertEqual(periods.first?.topArtists.first?.count, 5)
        XCTAssertEqual(periods.first?.totalPlays, 7, "all 2024 plays counted")
        XCTAssertEqual(periods.last?.topArtists.first?.artist, "Gamma")
    }

    func testTopPerYearCapIsApplied() async throws {
        var seed: [DatabaseManager.ImportedListen] = []
        for (i, name) in ["A", "B", "C", "D"].enumerated() {
            seed += plays(name, 2022, 10 - i)   // A:10, B:9, C:8, D:7 → distinct
        }
        try await db.appendImportedListens(seed, source: "test", zoneName: "T")

        let periods = try await db.tasteTimeMachine(topPerYear: 2)
        XCTAssertEqual(periods.count, 1)
        XCTAssertEqual(periods[0].topArtists.map { $0.artist }, ["A", "B"], "only the 2 heaviest, order by count")
        XCTAssertEqual(periods[0].totalPlays, 34, "total spans all artists, not just the top 2")
    }
}
