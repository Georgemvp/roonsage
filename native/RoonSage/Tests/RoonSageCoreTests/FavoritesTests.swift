import XCTest
@testable import RoonSageCore

final class FavoritesTests: XCTestCase {
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

    func testSetRemoveRoundTrip() async throws {
        try await db.setFavorite(.init(kind: "artist", key: "radiohead", title: "Radiohead", artist: nil))
        try await db.setFavorite(.init(kind: "album", key: "ok computer|radiohead",
                                       title: "OK Computer", artist: "Radiohead"))
        var all = try await db.allFavorites()
        XCTAssertEqual(all.count, 2)

        // Re-star is idempotent (upsert, no duplicate).
        try await db.setFavorite(.init(kind: "artist", key: "radiohead", title: "Radiohead", artist: nil))
        all = try await db.allFavorites()
        XCTAssertEqual(all.count, 2)

        try await db.removeFavorite(kind: "artist", key: "radiohead")
        all = try await db.allFavorites()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.kind, "album")
    }

    func testKeysAreContentDerived() {
        XCTAssertEqual(FavoriteKind.artistKey("Radiohead"), "radiohead")
        XCTAssertEqual(FavoriteKind.albumKey(album: "OK Computer", artist: "Radiohead"),
                       "ok computer|radiohead")
        XCTAssertEqual(FavoriteKind.albumKey(album: "Solo", artist: nil), "solo|")
    }
}
