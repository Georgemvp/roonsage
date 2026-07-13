import Foundation
@testable import RoonSageCore
import XCTest

/// Gap C (AudioMuse-audit): FTS5-zoek door songteksten (migration v41 +
/// `searchLyrics`), inclusief de trigger-sync bij lyrics-updates.
final class LyricsSearchTests: XCTestCase {

    private var db: DatabaseManager!
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-lyrics-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try DatabaseManager(url: dir.appendingPathComponent("library.db"))
    }

    override func tearDown() {
        db = nil
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func insertTrack(_ id: String, title: String, matchKey: String) async throws {
        try await db.upsertTracks([TrackRecord(
            id: id, title: title, artist: "Artist", album: "Album", matchKey: matchKey)])
    }

    func testSearchFindsPhraseAndSkipsMisses() async throws {
        try await insertTrack("t1", title: "Sunshine Song", matchKey: "k1")
        try db.upsertLyrics(matchKey: "k1",
                            lyrics: Lyrics(plain: "walking on sunshine and it feels so good",
                                           synced: nil, isInstrumental: false),
                            source: "test")

        let hits = try await db.searchLyrics(query: "sunshine")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.track.id, "t1")
        XCTAssertTrue(hits.first?.snippet.lowercased().contains("sunshine") ?? false,
                      "snippet toont het gevonden fragment")

        let misses = try await db.searchLyrics(query: "rainbow")
        XCTAssertTrue(misses.isEmpty)
    }

    func testUpdateKeepsFTSInSync() async throws {
        try await insertTrack("t2", title: "Changing Song", matchKey: "k2")
        try db.upsertLyrics(matchKey: "k2",
                            lyrics: Lyrics(plain: "original moonlight verse",
                                           synced: nil, isInstrumental: false),
                            source: "test")
        // Upsert over dezelfde key: de AU-trigger moet de oude tekst uit de
        // FTS-index halen en de nieuwe erin zetten.
        try db.upsertLyrics(matchKey: "k2",
                            lyrics: Lyrics(plain: "rewritten starlight verse",
                                           synced: nil, isInstrumental: false),
                            source: "test")

        let old = try await db.searchLyrics(query: "moonlight")
        XCTAssertTrue(old.isEmpty, "oude tekst mag niet meer matchen")
        let new = try await db.searchLyrics(query: "starlight")
        XCTAssertEqual(new.map(\.track.id), ["t2"])
    }

    func testNegativeRowsDoNotMatch() async throws {
        try await insertTrack("t3", title: "Instrumental", matchKey: "k3")
        // nil = negatieve cache (found=0) — mag nooit in zoekresultaten opduiken.
        try db.upsertLyrics(matchKey: "k3", lyrics: nil, source: "test")
        let hits = try await db.searchLyrics(query: "instrumental")
        XCTAssertTrue(hits.isEmpty)
    }
}
