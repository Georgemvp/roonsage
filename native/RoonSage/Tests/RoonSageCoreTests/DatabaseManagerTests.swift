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

    func testImportedListensAreIdempotentAndScoped() async throws {
        // Eigen Roon-listen (bron 'roon') op een bekend tijdstip.
        try await db.logListen(title: "Live Track", artist: "A", album: nil, zoneID: "z", zoneName: "Salon")
        let roonEarliestOpt = try await db.earliestListen(excludingSource: "lastfm")
        let roonEarliest = try XCTUnwrap(roonEarliestOpt)
        XCTAssertFalse(roonEarliest.isEmpty)

        let entries = [
            DatabaseManager.ImportedListen(title: "Old 1", artist: "B", album: "Album", playedAt: "2024-03-01T10:00:00Z"),
            DatabaseManager.ImportedListen(title: "Old 2", artist: "C", album: nil, playedAt: "2025-07-15T20:00:00Z"),
        ]
        try await db.replaceImportedListens(entries, source: "lastfm", zoneName: "Last.fm")
        let importedCount1 = try await db.importedListenCount(source: "lastfm")
        XCTAssertEqual(importedCount1, 2)
        let total1 = try await db.totalListens()
        XCTAssertEqual(total1, 3)  // 1 roon + 2 lastfm

        // Her-import bouwt opnieuw op zonder te dupliceren.
        try await db.replaceImportedListens(entries, source: "lastfm", zoneName: "Last.fm")
        let importedCount2 = try await db.importedListenCount(source: "lastfm")
        XCTAssertEqual(importedCount2, 2)
        let total2 = try await db.totalListens()
        XCTAssertEqual(total2, 3)

        // De geïmporteerde historie voedt het jaaroverzicht van een eerder jaar.
        let plays2025 = try await db.yearInReview(year: 2025).totalPlays
        XCTAssertEqual(plays2025, 1)
        let plays2024 = try await db.yearInReview(year: 2024).totalPlays
        XCTAssertEqual(plays2024, 1)

        // earliestListen negeert de Last.fm-bron: blijft de Roon-listen.
        let roonEarliestAgain = try await db.earliestListen(excludingSource: "lastfm")
        XCTAssertEqual(roonEarliestAgain, roonEarliest)
    }

    func testGenreMappingBatched() async throws {
        try db.upsertTracks([
            track("a", "Song A", "X", album: "Blue"),
            track("b", "Song B", "Y", album: "Blue"),
            track("c", "Song C", "Z", album: "Red"),
        ])
        try db.applyGenreMapping(["blue": ["Jazz", "Soul"], "red": ["Rock"]])
        XCTAssertEqual(try db.genreCount(), 3)  // distinct genres

        var opts = DatabaseManager.FilterOptions()
        opts.genres = ["Jazz"]
        let jazz = try await db.filterTracks(options: opts)
        XCTAssertEqual(Set(jazz.map { $0.id }), ["a", "b"])
    }

    func testTopTracksJoin() async throws {
        try db.upsertTracks([track("a", "Hit", "Band"), track("b", "Filler", "Other")])
        for _ in 0..<3 { try await db.logListen(title: "Hit", artist: "Band", album: nil, zoneID: "z", zoneName: "Z") }
        try await db.logListen(title: "Filler", artist: "Other", album: nil, zoneID: "z", zoneName: "Z")

        let top = try await db.topTracks(limit: 10)
        XCTAssertEqual(top.first?.id, "a")            // most played first
        XCTAssertEqual(top.count, 2)
        // No duplicate rows even though tracks table could hold dupes.
        XCTAssertEqual(Set(top.map { $0.id }).count, top.count)
    }

    func testForgottenFavoritesArtistCap() async throws {
        try db.upsertTracks([
            track("a1", "A1", "SameArtist"), track("a2", "A2", "SameArtist"), track("a3", "A3", "SameArtist"),
        ])
        // Old plays (well beyond the 60-day cutoff) so they count as "forgotten".
        try logOldListens("A1", "SameArtist", times: 5)
        try logOldListens("A2", "SameArtist", times: 4)
        try logOldListens("A3", "SameArtist", times: 3)

        let forgotten = try await db.forgottenFavorites(days: 1, limit: 10)
        // Max 2 per artist.
        XCTAssertEqual(forgotten.count, 2)
        XCTAssertEqual(Set(forgotten.map { $0.id }), ["a1", "a2"])
    }

    func testResolveCurrentTracks() async throws {
        try db.upsertTracks([track("new1", "Shared Title", "Resolved Artist")])
        // Saved copy carries a stale id but matching title+artist.
        let saved = TrackRecord(id: "stale", title: "Shared Title", artist: "Resolved Artist")
        let resolved = try await db.resolveCurrentTracks([saved])
        XCTAssertEqual(resolved.first?.id, "new1")

        // Saved with nil artist still matches by title.
        let savedNil = TrackRecord(id: "stale2", title: "Shared Title", artist: nil)
        let resolvedNil = try await db.resolveCurrentTracks([savedNil])
        XCTAssertEqual(resolvedNil.first?.id, "new1")

        // No match returns empty.
        let none = TrackRecord(id: "x", title: "Nonexistent", artist: "Nobody")
        let resolvedNone = try await db.resolveCurrentTracks([none])
        XCTAssertTrue(resolvedNone.isEmpty)
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

    // MARK: - FTS5 search

    func testFTSSearchMatchesPrefixAndStaysInSync() async throws {
        try db.upsertTracks([
            track("a", "Don't Look Back in Anger", "Oasis", album: "Morning Glory"),
            track("b", "Champagne Supernova", "Oasis", album: "Morning Glory"),
            track("c", "Karma Police", "Radiohead", album: "OK Computer"),
        ])

        // Prefix match on title token.
        XCTAssertEqual(try db.searchTracks(query: "champ").map(\.id), ["b"])
        // Artist match.
        XCTAssertEqual(Set(try db.searchTracks(query: "oasis").map(\.id)), ["a", "b"])
        // Multi-token AND across columns.
        XCTAssertEqual(try db.searchTracks(query: "radiohead karma").map(\.id), ["c"])
        // FTS operators in user input are neutralised by token quoting.
        XCTAssertEqual(try db.searchTracks(query: "karma OR oasis").count, 0)

        // UPDATE keeps the index in sync (upsert path).
        var renamed = track("c", "Paranoid Android", "Radiohead", album: "OK Computer")
        renamed.matchKey = "radiohead|paranoid android"
        try db.upsertTracks([renamed])
        XCTAssertEqual(try db.searchTracks(query: "karma").count, 0)
        XCTAssertEqual(try db.searchTracks(query: "paranoid").map(\.id), ["c"])

        // DELETE keeps the index in sync.
        try await db.pool.write { try $0.execute(sql: "DELETE FROM tracks WHERE id='b'") }
        XCTAssertEqual(try db.searchTracks(query: "champ").count, 0)

        // browseTracks + filterTracks route through FTS too.
        let browsed = try await db.browseTracks(query: "parano", tag: nil)
        XCTAssertEqual(browsed.map(\.id), ["c"])
        var opts = DatabaseManager.FilterOptions()
        opts.keywords = "android"
        opts.excludeLive = false
        let filtered = try await db.filterTracks(options: opts)
        XCTAssertEqual(filtered.map(\.id), ["c"])
    }
}
