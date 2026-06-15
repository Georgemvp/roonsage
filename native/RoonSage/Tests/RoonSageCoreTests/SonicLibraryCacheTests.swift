import XCTest
@testable import RoonSageCore

/// SonicLibraryCache (C4): caches the expensive tracks↔features join,
/// reloads only after invalidate().
final class SonicLibraryCacheTests: XCTestCase {
    private var dbURL: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-sonic-cache-\(UUID().uuidString)", isDirectory: true)
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

    private func seed(_ id: String, _ title: String, _ artist: String, bpm: Double) async throws {
        let mk = "\(artist)|\(title)".lowercased()
        try await db.upsertTracks([TrackRecord(
            id: id, title: title, artist: artist, album: "Album",
            albumKey: "ak", year: 2000, matchKey: mk)])
        try await db.upsertAudioFeatures([DatabaseManager.AudioFeatureRow(
            matchKey: mk, bpm: bpm, camelot: "8A", keyRoot: "A",
            keyMode: "minor", energy: 0.5, duration: 200, tags: nil)])
    }

    func testCachesUntilInvalidated() async throws {
        try await seed("t1", "One", "Artist", bpm: 120)
        let cache = SonicLibraryCache()

        let first = await cache.tracks(from: db)
        XCTAssertEqual(first.count, 1)

        // New row lands in SQLite, but the cache must keep serving the old set…
        try await seed("t2", "Two", "Artist", bpm: 100)
        let second = await cache.tracks(from: db)
        XCTAssertEqual(second.count, 1)

        // …until invalidated.
        await cache.invalidate()
        let third = await cache.tracks(from: db)
        XCTAssertEqual(third.count, 2)
    }

    func testConcurrentFirstLoadsShareOneResult() async throws {
        try await seed("t1", "One", "Artist", bpm: 120)
        let cache = SonicLibraryCache()
        let db = self.db!

        // Hammer the cold cache concurrently — every caller gets the full set.
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask { await cache.tracks(from: db).count }
            }
            return await group.reduce(into: [Int]()) { $0.append($1) }
        }
        XCTAssertEqual(counts, Array(repeating: 1, count: 8))
    }
}
