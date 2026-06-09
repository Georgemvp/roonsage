import XCTest
@testable import RoonSageCore

/// Exercises the batched-insert and JOIN-based query paths in DatabaseManager
/// against a throwaway on-disk database.
final class DatabaseManagerTests: XCTestCase {
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

    private func track(_ id: String, _ title: String, _ artist: String, album: String = "Album", year: Int? = 2000) -> TrackRecord {
        TrackRecord(id: id, title: title, artist: artist, album: album, albumKey: "ak-\(album)", year: year, matchKey: "\(artist)|\(title)".lowercased())
    }

    func testBatchUpsertTracksRoundTrips() throws {
        // More than one chunk (rowsPerChunk for 9 cols = 100) to exercise chunking.
        let records = (0..<250).map { track("t\($0)", "Title \($0)", "Artist \($0 % 7)") }
        try db.upsertTracks(records)
        XCTAssertEqual(try db.trackCount(), 250)

        // Re-upsert with a changed title should UPDATE, not duplicate.
        var changed = records[0]
        changed.title = "Renamed"
        try db.upsertTracks([changed])
        XCTAssertEqual(try db.trackCount(), 250)
        let hit = try db.searchTracks(query: "Renamed")
        XCTAssertEqual(hit.first?.id, "t0")
    }

    func testGenreMappingBatched() throws {
        try db.upsertTracks([
            track("a", "Song A", "X", album: "Blue"),
            track("b", "Song B", "Y", album: "Blue"),
            track("c", "Song C", "Z", album: "Red"),
        ])
        try db.applyGenreMapping(["blue": ["Jazz", "Soul"], "red": ["Rock"]])
        XCTAssertEqual(try db.genreCount(), 3)  // distinct genres

        var opts = DatabaseManager.FilterOptions()
        opts.genres = ["Jazz"]
        let jazz = try db.filterTracks(options: opts)
        XCTAssertEqual(Set(jazz.map { $0.id }), ["a", "b"])
    }

    func testTopTracksJoin() throws {
        try db.upsertTracks([track("a", "Hit", "Band"), track("b", "Filler", "Other")])
        for _ in 0..<3 { try db.logListen(title: "Hit", artist: "Band", album: nil, zoneID: "z", zoneName: "Z") }
        try db.logListen(title: "Filler", artist: "Other", album: nil, zoneID: "z", zoneName: "Z")

        let top = try db.topTracks(limit: 10)
        XCTAssertEqual(top.first?.id, "a")            // most played first
        XCTAssertEqual(top.count, 2)
        // No duplicate rows even though tracks table could hold dupes.
        XCTAssertEqual(Set(top.map { $0.id }).count, top.count)
    }

    func testForgottenFavoritesArtistCap() throws {
        try db.upsertTracks([
            track("a1", "A1", "SameArtist"), track("a2", "A2", "SameArtist"), track("a3", "A3", "SameArtist"),
        ])
        // Old plays (well beyond the 60-day cutoff) so they count as "forgotten".
        try logOldListens("A1", "SameArtist", times: 5)
        try logOldListens("A2", "SameArtist", times: 4)
        try logOldListens("A3", "SameArtist", times: 3)

        let forgotten = try db.forgottenFavorites(days: 1, limit: 10)
        // Max 2 per artist.
        XCTAssertEqual(forgotten.count, 2)
        XCTAssertEqual(Set(forgotten.map { $0.id }), ["a1", "a2"])
    }

    func testResolveCurrentTracks() throws {
        try db.upsertTracks([track("new1", "Shared Title", "Resolved Artist")])
        // Saved copy carries a stale id but matching title+artist.
        let saved = TrackRecord(id: "stale", title: "Shared Title", artist: "Resolved Artist")
        let resolved = try db.resolveCurrentTracks([saved])
        XCTAssertEqual(resolved.first?.id, "new1")

        // Saved with nil artist still matches by title.
        let savedNil = TrackRecord(id: "stale2", title: "Shared Title", artist: nil)
        XCTAssertEqual(try db.resolveCurrentTracks([savedNil]).first?.id, "new1")

        // No match returns empty.
        let none = TrackRecord(id: "x", title: "Nonexistent", artist: "Nobody")
        XCTAssertTrue(try db.resolveCurrentTracks([none]).isEmpty)
    }

    // MARK: - Helpers

    private func logOldListens(_ title: String, _ artist: String, times: Int) throws {
        try db.pool.write { db in
            for _ in 0..<times {
                try db.execute(
                    sql: "INSERT INTO listening_history (title, artist, played_at) VALUES (?, ?, ?)",
                    arguments: [title, artist, "2000-01-01T00:00:00Z"]
                )
            }
        }
    }
}

extension DatabaseManagerTests {
    /// The analyzer feed contains duplicate match_keys (39911 rows -> ~35714
    /// unique). A multi-row INSERT ... ON CONFLICT DO UPDATE hits the same key
    /// twice within one statement — this must not throw.
    func testUpsertAudioFeaturesWithDuplicateKeys() throws {
        var rows: [DatabaseManager.AudioFeatureRow] = []
        for i in 0..<250 {
            let key = "key-\(i % 120)"   // duplicates within and across chunks
            rows.append(DatabaseManager.AudioFeatureRow(
                matchKey: key, bpm: Double(100 + i), camelot: "8A", keyRoot: "A",
                keyMode: "minor", energy: 0.5, duration: 200, tags: nil))
        }
        try db.upsertAudioFeatures(rows)
        let count = try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM track_audio_features") ?? 0 }
        XCTAssertEqual(count, 120)
        // Last write wins: key-0 appears at i=0 and i=120 and i=240 -> bpm 340.
        let bpm = try db.pool.read { try Double.fetchOne($0, sql: "SELECT bpm FROM track_audio_features WHERE match_key='key-0'") }
        XCTAssertEqual(bpm, 340)
    }
}
