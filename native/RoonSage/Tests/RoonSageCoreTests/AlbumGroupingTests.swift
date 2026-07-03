import XCTest
@testable import RoonSageCore

final class AlbumGroupingTests: XCTestCase {
    func testVersionKeyCollapsesEditions() {
        let base = AlbumGrouping.versionKey(album: "OK Computer", artist: "Radiohead")
        XCTAssertEqual(AlbumGrouping.versionKey(album: "OK Computer (2017 Remaster)", artist: "Radiohead"), base)
        XCTAssertEqual(AlbumGrouping.versionKey(album: "OK Computer (Deluxe Edition)", artist: "radiohead"), base)
        XCTAssertNotEqual(AlbumGrouping.versionKey(album: "Kid A", artist: "Radiohead"), base)
        XCTAssertNotEqual(AlbumGrouping.versionKey(album: "OK Computer", artist: "Someone Else"), base)
    }

    func testClassifyLiveNeedsWordBoundary() {
        XCTAssertEqual(AlbumGrouping.classify(album: "Alchemy: Dire Straits Live", trackCount: 12), .live)
        XCTAssertEqual(AlbumGrouping.classify(album: "MTV Unplugged in New York", trackCount: 14), .live)
        XCTAssertEqual(AlbumGrouping.classify(album: "Alive & Kicking Sounds", trackCount: 10), .album,
                       "'Alive' must not match the live marker")
    }

    func testClassifyCompilation() {
        XCTAssertEqual(AlbumGrouping.classify(album: "Greatest Hits", trackCount: 18), .compilation)
        XCTAssertEqual(AlbumGrouping.classify(album: "The Best of Bowie", trackCount: 20), .compilation)
    }

    func testClassifyByTrackCount() {
        XCTAssertEqual(AlbumGrouping.classify(album: "Some Single", trackCount: 2), .epSingle)
        XCTAssertEqual(AlbumGrouping.classify(album: "Some EP", trackCount: 5), .epSingle)
        XCTAssertEqual(AlbumGrouping.classify(album: "Full Length", trackCount: 11), .album)
        XCTAssertEqual(AlbumGrouping.classify(album: "Unknown Count", trackCount: 0), .album)
    }
}
