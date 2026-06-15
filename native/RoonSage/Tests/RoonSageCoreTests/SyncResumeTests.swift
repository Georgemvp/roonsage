import XCTest
@testable import RoonSageCore

/// Resumable sync (DatabaseManager+Sync): album checkpoints per generation,
/// per-album replace instead of a destructive upfront clear, stale-row
/// deletion only after a completed walk.
final class SyncResumeTests: XCTestCase {
    private var dbURL: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-sync-resume-\(UUID().uuidString)", isDirectory: true)
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

    private func rec(_ id: String, _ title: String, album: String) -> TrackRecord {
        TrackRecord(id: id, title: title, artist: "Artist", album: album, albumKey: "ak-\(id)")
    }

    func testInterruptedRunResumesSameGeneration() async throws {
        // Fresh run, album A completed, then "interrupted" (no finish).
        let run1 = try await db.beginSyncRun()
        XCTAssertEqual(run1.generation, 1)
        XCTAssertFalse(run1.resumed)
        try await db.replaceAlbumTracks([rec("a1", "One", album: "A")],
                                  albumTitle: "A", fingerprint: "a|artist • 2000", generation: run1.generation)

        // Resume: same generation, album A is checkpointed, rows intact.
        let run2 = try await db.beginSyncRun()
        XCTAssertEqual(run2.generation, 1)
        XCTAssertTrue(run2.resumed)
        XCTAssertEqual(run2.completedAlbums, ["a|artist • 2000"])
        let count = try await db.trackCount()
        XCTAssertEqual(count, 1)
    }

    func testFinishStartsFreshGenerationNextTime() async throws {
        let run1 = try await db.beginSyncRun()
        try await db.replaceAlbumTracks([rec("a1", "One", album: "A")],
                                  albumTitle: "A", fingerprint: "fpA", generation: run1.generation)
        try await db.finishSyncRun(generation: run1.generation)

        let run2 = try await db.beginSyncRun()
        XCTAssertEqual(run2.generation, 2)
        XCTAssertFalse(run2.resumed)
        XCTAssertTrue(run2.completedAlbums.isEmpty)
    }

    func testVanishedAlbumDroppedOnlyAtFinish() async throws {
        // Gen 1: albums A + B synced and finished.
        let run1 = try await db.beginSyncRun()
        try await db.replaceAlbumTracks([rec("a1", "One", album: "A")],
                                  albumTitle: "A", fingerprint: "fpA", generation: run1.generation)
        try await db.replaceAlbumTracks([rec("b1", "Two", album: "B")],
                                  albumTitle: "B", fingerprint: "fpB", generation: run1.generation)
        try await db.finishSyncRun(generation: run1.generation)
        let countAfterGen1 = try await db.trackCount()
        XCTAssertEqual(countAfterGen1, 2)

        // Gen 2: only A still exists in Roon. B's rows must survive the walk…
        let run2 = try await db.beginSyncRun()
        try await db.replaceAlbumTracks([rec("a1-new", "One", album: "A")],
                                  albumTitle: "A", fingerprint: "fpA", generation: run2.generation)
        let countMidWalk = try await db.trackCount()
        XCTAssertEqual(countMidWalk, 2, "vanished album must not be dropped mid-walk")

        // …and disappear only when the walk completes.
        try await db.finishSyncRun(generation: run2.generation)
        let countAfterFinish = try await db.trackCount()
        XCTAssertEqual(countAfterFinish, 1)
        let survivor = try await db.searchTracks(query: "One").first?.id
        XCTAssertEqual(survivor, "a1-new")
    }

    func testRewalkReplacesOldSessionRowsWithoutDuplicates() async throws {
        // Same album, new Roon session → new item_keys. Replace, don't duplicate.
        let run1 = try await db.beginSyncRun()
        try await db.replaceAlbumTracks([rec("old-key-1", "One", album: "A"), rec("old-key-2", "Two", album: "A")],
                                  albumTitle: "A", fingerprint: "fpA", generation: run1.generation)
        try await db.finishSyncRun(generation: run1.generation)

        let run2 = try await db.beginSyncRun()
        try await db.replaceAlbumTracks([rec("new-key-1", "One", album: "A"), rec("new-key-2", "Two", album: "A")],
                                  albumTitle: "A", fingerprint: "fpA", generation: run2.generation)
        let countBeforeFinish = try await db.trackCount()
        XCTAssertEqual(countBeforeFinish, 2)
        try await db.finishSyncRun(generation: run2.generation)
        let countAfterFinish = try await db.trackCount()
        XCTAssertEqual(countAfterFinish, 2)
    }

    func testLegacyNullFingerprintRowsReplacedByTitle() async throws {
        // Pre-v10 rows have album_fp NULL; the first re-walk of that album
        // must replace them (matched by title), not duplicate them.
        try await db.upsertTracks([rec("legacy-1", "One", album: "A")])
        let run = try await db.beginSyncRun()
        try await db.replaceAlbumTracks([rec("fresh-1", "One", album: "A")],
                                  albumTitle: "A", fingerprint: "fpA", generation: run.generation)
        let count = try await db.trackCount()
        XCTAssertEqual(count, 1)
        let survivor = try await db.searchTracks(query: "One").first?.id
        XCTAssertEqual(survivor, "fresh-1")
    }

    func testDuplicateEditionAppendsInsteadOfReplacing() async throws {
        // Two albums with an identical fingerprint in one walk (same title/
        // artist/year editions): the second must append, not wipe the first.
        let run = try await db.beginSyncRun()
        try await db.replaceAlbumTracks([rec("ed1-t1", "One", album: "A")],
                                  albumTitle: "A", fingerprint: "fpA", generation: run.generation)
        try await db.replaceAlbumTracks([rec("ed2-t1", "One (alt)", album: "A")],
                                  albumTitle: "A", fingerprint: "fpA", generation: run.generation, append: true)
        let count = try await db.trackCount()
        XCTAssertEqual(count, 2)
    }
}
