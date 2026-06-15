import XCTest
@testable import RoonSageCore

/// Library share (Mac → iPhone): exportLibraryJSON / importLibrary roundtrip.
final class LibraryShareTests: XCTestCase {
    private var dbURL: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-share-\(UUID().uuidString)", isDirectory: true)
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

    func testExportImportRoundtrip() async throws {
        try await db.upsertTracks([
            TrackRecord(id: "roon-key-1", title: "Song One", artist: "Artist A", album: "Blue",
                        albumKey: "ak1", year: 1999, isLive: false, matchKey: "artist a|song one", imageKey: "img1"),
            TrackRecord(id: "roon-key-2", title: "Song Two (Live)", artist: "Artist B", album: "Red",
                        albumKey: "ak2", year: 2005, isLive: true, matchKey: "artist b|song two"),
        ])
        try await db.applyGenreMapping(["blue": ["Jazz", "Soul"], "red": ["Rock"]])

        let json = try await db.exportLibraryJSON()

        // Import into a second database (the "iPhone").
        let dir2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-share-dst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir2) }
        let dst = try DatabaseManager(url: dir2.appendingPathComponent("library.db"))

        let count = try await dst.importLibrary(json: json)
        XCTAssertEqual(count, 2)
        let dstCount = try await dst.trackCount()
        XCTAssertEqual(dstCount, 2)

        // Metadata survives; ids became synthetic import:: keys (the source's
        // Roon item_keys are session-scoped and useless on this device).
        let oneResult = try await dst.searchTracks(query: "Song One").first
        let one = try XCTUnwrap(oneResult)
        XCTAssertTrue(one.id.hasPrefix("import::"), "got id \(one.id)")
        XCTAssertEqual(one.artist, "Artist A")
        XCTAssertEqual(one.year, 1999)
        XCTAssertEqual(one.matchKey, "artist a|song one")
        XCTAssertEqual(one.imageKey, "img1")

        let twoResult = try await dst.searchTracks(query: "Song Two").first
        let two = try XCTUnwrap(twoResult)
        XCTAssertTrue(two.isLive)

        // Genres came along.
        let dstGenreCount = try await dst.genreCount()
        XCTAssertEqual(dstGenreCount, 3)

        // Import counts as a completed sync: no interrupted-run leftovers.
        XCTAssertNotNil(try dst.syncStateValue(forKey: "last_sync"))
        XCTAssertEqual(try dst.syncStateValue(forKey: "sync_in_progress"), "0")
    }

    func testImportReplacesExistingLibrary() async throws {
        try await db.upsertTracks([TrackRecord(id: "stale", title: "Old Track", artist: "X")])

        let json = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "tracks": [["t": "New Track", "a": "Y"]],
        ])
        let imported = try await db.importLibrary(json: json)
        XCTAssertEqual(imported, 1)
        let count = try await db.trackCount()
        XCTAssertEqual(count, 1)
        let oldEmpty = try await db.searchTracks(query: "Old Track").isEmpty
        XCTAssertTrue(oldEmpty)
    }

    func testImportRejectsMalformedPayload() async throws {
        // XCTAssertThrowsError can't await, so do/catch the async throws directly.
        do { _ = try await db.importLibrary(json: Data("{\"nope\":true}".utf8)); XCTFail("expected throw") } catch {}
        do { _ = try await db.importLibrary(json: Data("{\"tracks\":[]}".utf8)); XCTFail("expected throw") } catch {}
    }

    func testDuplicateTitleArtistKeysStayUnique() async throws {
        // Same song on two albums → both must survive (unique synthetic PKs).
        let json = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "tracks": [
                ["t": "Same Song", "a": "Artist", "al": "Album One"],
                ["t": "Same Song", "a": "Artist", "al": "Album Two"],
            ],
        ])
        let imported = try await db.importLibrary(json: json)
        XCTAssertEqual(imported, 2)
        let count = try await db.trackCount()
        XCTAssertEqual(count, 2)
    }
}
