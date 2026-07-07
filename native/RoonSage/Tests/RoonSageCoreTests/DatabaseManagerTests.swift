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

    func testBatchUpsertTracksRoundTrips() async throws {
        // More than one chunk (rowsPerChunk for 9 cols = 100) to exercise chunking.
        let records = (0..<250).map { track("t\($0)", "Title \($0)", "Artist \($0 % 7)") }
        try await db.upsertTracks(records)
        let count1 = try await db.trackCount()
        XCTAssertEqual(count1, 250)

        // Re-upsert with a changed title should UPDATE, not duplicate.
        var changed = records[0]
        changed.title = "Renamed"
        try await db.upsertTracks([changed])
        let count2 = try await db.trackCount()
        XCTAssertEqual(count2, 250)
        let hit = try await db.searchTracks(query: "Renamed")
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

    func testFilterTracksPaginatesWithOffset() async throws {
        // 250 tracks, paged 100 at a time → 100 / 100 / 50, disjoint, full coverage.
        let records = (0..<250).map { track("p\($0)", "Title \(String(format: "%03d", $0))", "Artist \($0 % 5)") }
        try await db.upsertTracks(records)

        var opts = DatabaseManager.FilterOptions()
        opts.limit = 100
        opts.offset = 0
        let page1 = try await db.filterTracks(options: opts)
        opts.offset = 100
        let page2 = try await db.filterTracks(options: opts)
        opts.offset = 200
        let page3 = try await db.filterTracks(options: opts)

        XCTAssertEqual(page1.count, 100)
        XCTAssertEqual(page2.count, 100)
        XCTAssertEqual(page3.count, 50)   // short last page → the view flips reachedEnd

        let ids = Set(page1.map(\.id)).union(page2.map(\.id)).union(page3.map(\.id))
        XCTAssertEqual(ids.count, 250, "pages must together cover every track")
        XCTAssertTrue(Set(page1.map(\.id)).isDisjoint(with: page2.map(\.id)), "pages must not overlap")
    }

    func testGenreMappingBatched() async throws {
        try await db.upsertTracks([
            track("a", "Song A", "X", album: "Blue"),
            track("b", "Song B", "Y", album: "Blue"),
            track("c", "Song C", "Z", album: "Red"),
        ])
        try await db.applyGenreMapping(["blue": ["Jazz", "Soul"], "red": ["Rock"]])
        let genreCount = try await db.genreCount()
        XCTAssertEqual(genreCount, 3)  // distinct genres

        var opts = DatabaseManager.FilterOptions()
        opts.genres = ["Jazz"]
        let jazz = try await db.filterTracks(options: opts)
        XCTAssertEqual(Set(jazz.map { $0.id }), ["a", "b"])
    }

    func testTopTracksJoin() async throws {
        try await db.upsertTracks([track("a", "Hit", "Band"), track("b", "Filler", "Other")])
        for _ in 0..<3 { try await db.logListen(title: "Hit", artist: "Band", album: nil, zoneID: "z", zoneName: "Z") }
        try await db.logListen(title: "Filler", artist: "Other", album: nil, zoneID: "z", zoneName: "Z")

        let top = try await db.topTracks(limit: 10)
        XCTAssertEqual(top.first?.id, "a")            // most played first
        XCTAssertEqual(top.count, 2)
        // No duplicate rows even though tracks table could hold dupes.
        XCTAssertEqual(Set(top.map { $0.id }).count, top.count)
    }

    func testForgottenFavoritesArtistCap() async throws {
        try await db.upsertTracks([
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
        try await db.upsertTracks([track("new1", "Shared Title", "Resolved Artist")])
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

    func testResolveCurrentTracksAlignedKeepsPositionsForMisses() async throws {
        try await db.upsertTracks([track("lib1", "In Library", "Artist A")])
        let saved = [
            TrackRecord(id: "stale", title: "In Library", artist: "Artist A"),
            TrackRecord(id: "", title: "Qobuz Only", artist: "Artist B"),  // not in library
        ]
        let aligned = try await db.resolveCurrentTracksAligned(saved)
        XCTAssertEqual(aligned.count, 2, "one element per input, in order")
        XCTAssertEqual(aligned[0]?.id, "lib1", "library hit resolves to the current row")
        XCTAssertNil(aligned[1], "non-library track stays a miss so playback can fall back to Qobuz")
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
    func testUpsertAudioFeaturesWithDuplicateKeys() async throws {
        var rows: [DatabaseManager.AudioFeatureRow] = []
        for i in 0..<250 {
            let key = "key-\(i % 120)"   // duplicates within and across chunks
            rows.append(DatabaseManager.AudioFeatureRow(
                matchKey: key, bpm: Double(100 + i), camelot: "8A", keyRoot: "A",
                keyMode: "minor", energy: 0.5, duration: 200, tags: nil))
        }
        try await db.upsertAudioFeatures(rows)
        let count = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM track_audio_features") ?? 0 }
        XCTAssertEqual(count, 120)
        // Last write wins: key-0 appears at i=0 and i=120 and i=240 -> bpm 340.
        let bpm = try await db.pool.read { try Double.fetchOne($0, sql: "SELECT bpm FROM track_audio_features WHERE match_key='key-0'") }
        XCTAssertEqual(bpm, 340)
    }

    // MARK: - FTS5 search

    func testFTSSearchMatchesPrefixAndStaysInSync() async throws {
        try await db.upsertTracks([
            track("a", "Don't Look Back in Anger", "Oasis", album: "Morning Glory"),
            track("b", "Champagne Supernova", "Oasis", album: "Morning Glory"),
            track("c", "Karma Police", "Radiohead", album: "OK Computer"),
        ])

        // Prefix match on title token.
        let champHit = try await db.searchTracks(query: "champ").map(\.id)
        XCTAssertEqual(champHit, ["b"])
        // Artist match.
        let oasisHit = try await db.searchTracks(query: "oasis").map(\.id)
        XCTAssertEqual(Set(oasisHit), ["a", "b"])
        // Multi-token AND across columns.
        let radioheadKarmaHit = try await db.searchTracks(query: "radiohead karma").map(\.id)
        XCTAssertEqual(radioheadKarmaHit, ["c"])
        // FTS operators in user input are neutralised by token quoting.
        let karmaOrOasisCount = try await db.searchTracks(query: "karma OR oasis").count
        XCTAssertEqual(karmaOrOasisCount, 0)

        // UPDATE keeps the index in sync (upsert path).
        var renamed = track("c", "Paranoid Android", "Radiohead", album: "OK Computer")
        renamed.matchKey = "radiohead|paranoid android"
        try await db.upsertTracks([renamed])
        let karmaCount = try await db.searchTracks(query: "karma").count
        XCTAssertEqual(karmaCount, 0)
        let paranoidHit = try await db.searchTracks(query: "paranoid").map(\.id)
        XCTAssertEqual(paranoidHit, ["c"])

        // DELETE keeps the index in sync.
        try await db.pool.write { try $0.execute(sql: "DELETE FROM tracks WHERE id='b'") }
        let champCountAfterDelete = try await db.searchTracks(query: "champ").count
        XCTAssertEqual(champCountAfterDelete, 0)

        // browseTracks + filterTracks route through FTS too.
        let browsed = try await db.browseTracks(query: "parano", tag: nil)
        XCTAssertEqual(browsed.map(\.id), ["c"])
        var opts = DatabaseManager.FilterOptions()
        opts.keywords = "android"
        opts.excludeLive = false
        let filtered = try await db.filterTracks(options: opts)
        XCTAssertEqual(filtered.map(\.id), ["c"])
    }

    func testDedupedScrobblesSkipLocalRoonPlays() async throws {
        // A local Roon play at a known time…
        try await db.logListen(title: "This House", artist: "The Boxer Rebellion",
                               album: "Union", zoneID: "z", zoneName: "Mac mini")
        let recent = try await db.recentListens(limit: 1)
        let roonTime = try XCTUnwrap(recent.first?.playedAt)
        let roonUTS = Int(try XCTUnwrap(ISO8601DateFormatter().date(from: roonTime)).timeIntervalSince1970)
        let iso = ISO8601DateFormatter()

        let scrobbles = [
            // Same track, 3 min later → Roon's own scrobble bouncing back: skip.
            DatabaseManager.ImportedListen(title: "This House", artist: "The Boxer Rebellion", album: "Union",
                playedAt: iso.string(from: Date(timeIntervalSince1970: Double(roonUTS + 180)))),
            // A genuinely external play (ARC etc.) far from any local listen: keep.
            DatabaseManager.ImportedListen(title: "Heaven Forbid", artist: "The Fray", album: nil,
                playedAt: "2024-01-01T09:00:00Z"),
        ]
        try await db.appendDedupedScrobbles(scrobbles, source: "lastfm", zoneName: "Last.fm")

        let lastfm = try await db.importedListenCount(source: "lastfm")
        XCTAssertEqual(lastfm, 1, "the bounced-back Roon scrobble is dropped, the external one kept")
        let total = try await db.totalListens()
        XCTAssertEqual(total, 2, "one Roon listen + one external scrobble")
    }

    func testTasteAnalysisSummarisesHistoryAndFeedback() async throws {
        try await db.upsertTracks([track("t1", "Song A", "Artist X", year: 1995)])
        try await db.pool.write { try $0.execute(sql: "INSERT INTO track_genres (track_id, genre) VALUES ('t1','Indie')") }
        try await db.logListen(title: "Song A", artist: "Artist X", album: "Album", zoneID: "z", zoneName: "Mac mini")
        try await db.setFeedback(matchKey: "artist x|song a", title: "Song A", artist: "Artist X", kind: "like")

        let a = try await db.tasteAnalysis()
        XCTAssertEqual(a.totalPlays, 1)
        XCTAssertEqual(a.likeCount, 1)
        XCTAssertEqual(a.dislikeCount, 0)
        XCTAssertEqual(a.topGenres.first?.label, "Indie")
        XCTAssertEqual(a.topDecades.first?.label, "1990s")
        XCTAssertEqual(a.topLikedArtists, ["Artist X"])
        XCTAssertEqual(a.partsOfDay.map(\.label), ["Ochtend", "Middag", "Avond", "Nacht"])
    }

    func testSyncExternalPlaylistsIsIdempotentAndScoped() async throws {
        func ext(_ id: String, _ name: String, _ titles: [String]) -> DatabaseManager.ExternalPlaylist {
            DatabaseManager.ExternalPlaylist(
                externalID: "listenbrainz:\(id)",
                name: name,
                tracks: titles.map { TrackRecord(id: "", title: $0, artist: "Artist", album: "Album") }
            )
        }

        // A user-curated playlist (NULL external_id) must survive every sync.
        _ = try await db.savePlaylist(name: "Mijn mix", tracks: [track("u1", "Eigen nummer", "Mij")])

        // First import: two LB playlists land alongside the user's.
        try await db.syncExternalPlaylists(sourcePrefix: "listenbrainz:", playlists: [
            ext("mbid-a", "Weekly Jams", ["A1", "A2", "A3"]),
            ext("mbid-b", "Daily Jams", ["B1"]),
        ])
        var all = try await db.listPlaylists()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.first(where: { $0.name == "Weekly Jams" })?.trackCount, 3)
        // Imported playlists carry a source label; the user's own does not.
        XCTAssertEqual(all.first(where: { $0.name == "Weekly Jams" })?.source, "listenbrainz")
        XCTAssertNil(all.first(where: { $0.name == "Mijn mix" })?.source)

        // Re-import identical data: no duplicates (upsert by external_id).
        try await db.syncExternalPlaylists(sourcePrefix: "listenbrainz:", playlists: [
            ext("mbid-a", "Weekly Jams", ["A1", "A2", "A3"]),
            ext("mbid-b", "Daily Jams", ["B1"]),
        ])
        all = try await db.listPlaylists()
        XCTAssertEqual(all.count, 3, "re-import must replace, not duplicate")

        // Upstream changes: 'a' renamed + retracked, 'b' removed. The user mix stays.
        try await db.syncExternalPlaylists(sourcePrefix: "listenbrainz:", playlists: [
            ext("mbid-a", "Weekly Jams (nieuw)", ["A1", "A4"]),
        ])
        all = try await db.listPlaylists()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains { $0.name == "Mijn mix" }, "user playlist untouched")
        let a = try XCTUnwrap(all.first(where: { $0.name == "Weekly Jams (nieuw)" }))
        XCTAssertEqual(a.trackCount, 2)
        let aTracks = try await db.playlistTracks(id: a.id)
        XCTAssertEqual(aTracks.map(\.title), ["A1", "A4"])

        // Empty import prunes all LB playlists but leaves the user's.
        try await db.syncExternalPlaylists(sourcePrefix: "listenbrainz:", playlists: [])
        all = try await db.listPlaylists()
        XCTAssertEqual(all.map(\.name), ["Mijn mix"])
    }

    func testExternalSourceLabelsAreScopedPerPrefix() async throws {
        try await db.syncExternalPlaylists(sourcePrefix: "lastfm:", playlists: [
            DatabaseManager.ExternalPlaylist(
                externalID: "lastfm:top:7day",
                name: "Last.fm Top · Laatste 7 dagen",
                tracks: [TrackRecord(id: "", title: "Song", artist: "Artist", album: nil)]
            ),
        ])
        let all = try await db.listPlaylists()
        XCTAssertEqual(all.first?.source, "lastfm")

        // A "lastfm:" reconcile must not touch listenbrainz playlists, and vice versa.
        try await db.syncExternalPlaylists(sourcePrefix: "listenbrainz:", playlists: [
            DatabaseManager.ExternalPlaylist(
                externalID: "listenbrainz:abc",
                name: "Weekly Jams",
                tracks: [TrackRecord(id: "", title: "Other", artist: "B", album: nil)]
            ),
        ])
        let both = try await db.listPlaylists()
        XCTAssertEqual(Set(both.compactMap(\.source)), ["lastfm", "listenbrainz"])
    }

    func testSkipCountAndThreshold() async throws {
        try await db.logSkip(matchKey: "a|x")
        try await db.logSkip(matchKey: "a|x")
        var heavy = try await db.heavilySkippedMatchKeys(minCount: 3)
        XCTAssertFalse(heavy.contains("a|x"), "2 skips is below the 3× threshold")
        try await db.logSkip(matchKey: "a|x")
        heavy = try await db.heavilySkippedMatchKeys(minCount: 3)
        XCTAssertTrue(heavy.contains("a|x"), "3 skips crosses the threshold")
    }

    func testExplicitLikeOverridesSkips() async throws {
        for _ in 0..<5 { try await db.logSkip(matchKey: "b|y") }
        try await db.setFeedback(matchKey: "b|y", title: "Y", artist: "B", kind: "like")
        let heavy = try await db.heavilySkippedMatchKeys(minCount: 3)
        XCTAssertFalse(heavy.contains("b|y"),
                       "a thumbs-up track is never an implicit dislike, however often skipped")
    }
}
