import XCTest
@testable import RoonSageCore

/// Covers the recency-decay "vergeten muziek" axis: the pure `ForgottenScore`
/// math and the `ForgottenMusicService` DB orchestration against a throwaway db.
final class ForgottenMusicServiceTests: XCTestCase {
    private var dbURL: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-forgotten-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Pure scoring

    func testNeverPlayedScoresAboveAnyPlayedAlbum() {
        let now = Date()
        let recent = ForgottenScore.score(lastPlayedAt: now.addingTimeInterval(-3 * 86_400), now: now, playCount: 1)
        let old = ForgottenScore.score(lastPlayedAt: now.addingTimeInterval(-2_000 * 86_400), now: now, playCount: 50)
        let never = ForgottenScore.score(lastPlayedAt: nil, now: now, playCount: 0)
        XCTAssertEqual(never, 1.0, accuracy: 1e-9, "never-played is the ceiling")
        XCTAssertGreaterThan(never, old, "never-played outranks even a long-ago, heavily-played album")
        XCTAssertGreaterThan(never, recent)
    }

    func testOlderLastPlayScoresHigherThanRecent() {
        let now = Date()
        let recent = ForgottenScore.score(lastPlayedAt: now.addingTimeInterval(-5 * 86_400), now: now, playCount: 3)
        let old = ForgottenScore.score(lastPlayedAt: now.addingTimeInterval(-400 * 86_400), now: now, playCount: 3)
        XCTAssertGreaterThan(old, recent, "the longer since you last heard it, the more forgotten")
    }

    func testPlayCountBreaksTiesUpward() {
        let now = Date()
        let last = now.addingTimeInterval(-300 * 86_400)
        let oneOff = ForgottenScore.score(lastPlayedAt: last, now: now, playCount: 1)
        let favourite = ForgottenScore.score(lastPlayedAt: last, now: now, playCount: 40)
        XCTAssertGreaterThan(favourite, oneOff, "a once-loved album edges out a one-off with the same last-heard date")
    }

    func testPickIndexIsDeterministicPerDayAndRotates() {
        let day100 = Date(timeIntervalSince1970: 100 * 86_400)   // fixed instants, TZ-stable via ForgottenScore.calendar
        let day101 = Date(timeIntervalSince1970: 101 * 86_400)
        let count = 7
        XCTAssertEqual(ForgottenScore.pickIndex(for: day100, count: count),
                       ForgottenScore.pickIndex(for: day100, count: count), "same day → same pick")
        XCTAssertNotEqual(ForgottenScore.pickIndex(for: day100, count: count),
                          ForgottenScore.pickIndex(for: day101, count: count), "next day → different pick")
        for c in 1...12 {
            let idx = ForgottenScore.pickIndex(for: day100, count: c)
            XCTAssertTrue((0..<c).contains(idx), "index in range for count \(c)")
        }
        XCTAssertEqual(ForgottenScore.pickIndex(for: day100, count: 0), 0, "empty pool → 0, no crash")
    }

    // MARK: - Service against a real db

    func testForgottenAlbumsRankByRecencyThenDepthAndSkipNeverPlayed() async throws {
        try await seedLibrary()
        let service = ForgottenMusicService(database: db)
        let albums = try await service.forgottenAlbums(now: now).map { $0.album }

        XCTAssertTrue(albums.contains("Fav"), "long-lost heavily-played album resurfaces")
        XCTAssertTrue(albums.contains("Old"))
        XCTAssertFalse(albums.contains("Never"), "never-played is not part of the forgotten (played) axis")
        // Among the two long-ago albums, the heavily-played favourite outranks the one-off.
        let fav = albums.firstIndex(of: "Fav")
        let old = albums.firstIndex(of: "Old")
        XCTAssertNotNil(fav); XCTAssertNotNil(old)
        XCTAssertLessThan(fav!, old!, "same last-heard date → higher play depth ranks first")
        // The recently-played album is the least forgotten of the played set.
        if let recent = albums.firstIndex(of: "Recent") {
            XCTAssertGreaterThan(recent, fav!, "recently played is the least forgotten")
        }
    }

    func testNeverPlayedAlbumsReturnsUnheardOnly() async throws {
        try await seedLibrary()
        let never = try await ForgottenMusicService(database: db).neverPlayedAlbums().map { $0.album }
        XCTAssertTrue(never.contains("Never"), "an owned album with zero listens is 'nog niet gehoord'")
        XCTAssertFalse(never.contains("Recent"), "a played album is not unheard")
    }

    func testAlbumOfTheDayIsStableWithinADay() async throws {
        try await seedLibrary()
        let service = ForgottenMusicService(database: db)
        let date = Date(timeIntervalSince1970: 100 * 86_400)
        let first = try await service.albumOfTheDay(on: date)
        let second = try await service.albumOfTheDay(on: date)
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.albumKey, second?.albumKey, "the same day yields the same album on repeated opens")
    }

    // MARK: - Fixtures

    private let now = Date()

    /// Four owned 3-track albums by distinct artists: two long-ago (a one-off and a
    /// deeply-played favourite), one just-played, one never played.
    private func seedLibrary() async throws {
        try await db.upsertTracks(
            albumTracks("Old", "A") + albumTracks("Fav", "B")
            + albumTracks("Recent", "C") + albumTracks("Never", "D"))
        let nowISO = ISO8601DateFormatter().string(from: now)
        try logAlbumListens("Old", "A", times: 2, at: "2001-01-01T00:00:00Z")
        try logAlbumListens("Fav", "B", times: 30, at: "2001-01-01T00:00:00Z")
        try logAlbumListens("Recent", "C", times: 5, at: nowISO)
        // "Never" gets no listens.
    }

    private func albumTracks(_ album: String, _ artist: String) -> [TrackRecord] {
        (0..<3).map { i in
            TrackRecord(id: "\(album)-\(i)", title: "\(album) \(i)", artist: artist,
                        album: album, albumKey: "ak-\(album)", year: 2000,
                        matchKey: "\(artist)|\(album) \(i)".lowercased())
        }
    }

    private func logAlbumListens(_ album: String, _ artist: String, times: Int, at playedAt: String) throws {
        try db.pool.write { db in
            for i in 0..<times {
                try db.execute(
                    sql: "INSERT INTO listening_history (title, artist, album, played_at) VALUES (?, ?, ?, ?)",
                    arguments: ["\(album) \(i)", artist, album, playedAt])
            }
        }
    }
}
