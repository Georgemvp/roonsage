import XCTest
@testable import RoonSageCore

/// Pins the lyrics DB layer: round-trip of plain + synced (karaoke) lyrics,
/// cached negatives, and the backfill's "missing" query.
final class LyricsStorageTests: XCTestCase {
    private var dbURL: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-lyrics-\(UUID().uuidString)", isDirectory: true)
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

    func testUnknownKeyReturnsNil() {
        XCTAssertNil(db.storedLyrics(matchKey: "nobody|nothing"))
    }

    func testSyncedRoundTrip() throws {
        let lyrics = Lyrics(
            plain: "line one\nline two",
            synced: [LyricLine(time: 1.0, text: "line one"), LyricLine(time: 3.5, text: "line two")])
        try db.upsertLyrics(matchKey: "artist|song", lyrics: lyrics, source: "lrclib")

        let back = db.storedLyrics(matchKey: "artist|song")
        XCTAssertEqual(back?.plain, "line one\nline two")
        XCTAssertEqual(back?.synced?.count, 2)
        XCTAssertEqual(back?.synced?.last?.time, 3.5)
        XCTAssertEqual(back?.synced?.first?.text, "line one")
    }

    func testCachedNegativeExistsButHasNoContent() throws {
        try db.upsertLyrics(matchKey: "artist|instrumental", lyrics: nil, source: "lrclib")
        let back = db.storedLyrics(matchKey: "artist|instrumental")
        XCTAssertNotNil(back)              // row exists → won't refetch
        XCTAssertEqual(back?.hasContent, false)
    }

    func testMissingQueryExcludesTracksThatHaveARow() async throws {
        try await db.upsertTracks([
            TrackRecord(id: "1", title: "Has", artist: "A", album: "X", albumKey: "x", year: 2000, matchKey: "a|has"),
            TrackRecord(id: "2", title: "Missing", artist: "B", album: "Y", albumKey: "y", year: 2001, matchKey: "b|missing"),
        ])
        try db.upsertLyrics(matchKey: "a|has", lyrics: Lyrics(plain: "x"), source: "lrclib")

        let missing = db.tracksMissingLyrics(limit: 50)
        XCTAssertEqual(missing.map(\.matchKey), ["b|missing"])
    }
}
