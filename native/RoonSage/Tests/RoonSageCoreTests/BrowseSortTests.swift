import XCTest
@testable import RoonSageCore

/// The LMS-style browse sorts: track_first_seen trigger semantics (survives the
/// delete+reinsert sync paths) and the pre-ranked match-key row fetch.
final class BrowseSortTests: XCTestCase {
    private var dbURL: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func track(_ id: String, _ title: String, _ artist: String) -> TrackRecord {
        TrackRecord(id: id, title: title, artist: artist, album: "Album", albumKey: "ak",
                    matchKey: "\(artist)|\(title)".lowercased())
    }

    func testFirstSeenSurvivesDeleteAndReinsert() async throws {
        try await db.upsertTracks([track("t1", "Song", "A")])
        let before = try await db.pool.read { db in
            try String.fetchOne(db, sql: "SELECT first_seen FROM track_first_seen WHERE match_key = 'a|song'")
        }
        XCTAssertNotNil(before, "trigger records first_seen on insert")

        // Simulate a resync: wipe + reinsert under a NEW Roon id.
        try await db.pool.write { db in try db.execute(sql: "DELETE FROM tracks") }
        try await db.upsertTracks([track("t1-new-id", "Song", "A")])
        let after = try await db.pool.read { db in
            try String.fetchOne(db, sql: "SELECT first_seen FROM track_first_seen WHERE match_key = 'a|song'")
        }
        XCTAssertEqual(before, after, "INSERT OR IGNORE keeps the original date across resyncs")
    }

    func testBrowseTracksRecentlyAddedOrders() async throws {
        try await db.upsertTracks([track("t1", "Old", "A")])
        // Backdate the first track, then add a newer one.
        try await db.pool.write { db in
            try db.execute(sql: "UPDATE track_first_seen SET first_seen = '2020-01-01T00:00:00Z'")
        }
        try await db.upsertTracks([track("t2", "New", "B")])
        let rows = try await db.browseTracks(query: "", tag: nil, order: .recentlyAdded)
        XCTAssertEqual(rows.map(\.title), ["New", "Old"])
    }

    func testTracksByMatchKeysPreservesInputRanking() async throws {
        try await db.upsertTracks([track("t1", "One", "A"), track("t2", "Two", "B"), track("t3", "Three", "C")])
        let rows = try await db.tracksByMatchKeys(["c|three", "a|one", "nope|missing", "b|two"])
        XCTAssertEqual(rows.map(\.title), ["Three", "One", "Two"],
                       "input order kept, unknown keys skipped")
        XCTAssertEqual(rows.first?.matchKey, "c|three")
    }
}
