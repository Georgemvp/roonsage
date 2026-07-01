@testable import RoonSageCore
import XCTest

/// The pure discovery filter rule table: in-library, already-listened,
/// permanent-block, reject cooldown, and score threshold — each in isolation.
final class DiscoveryFilterTests: XCTestCase {

    private func key(_ kind: RecommendationKind, _ artist: String, _ album: String? = nil) -> String {
        DiscoveryKey.dedupKey(kind: kind, artist: artist, album: album, artistMbid: nil, releaseGroupMbid: nil)
    }

    func testInLibraryArtistDropped() {
        let ctx = DiscoveryFilterContext(libraryArtists: ["queen"])
        XCTAssertEqual(
            DiscoveryFilter.rejectReason(kind: .artist, artist: "Queen", album: nil,
                                         dedupKey: key(.artist, "Queen"), score: 0.9, context: ctx),
            .inLibrary)
    }

    func testOwnedAlbumDroppedButUnownedAlbumByOwnedArtistKept() {
        // Gap-fill's whole point: an unowned album by an artist you DO own survives.
        let ctx = DiscoveryFilterContext(libraryArtists: ["queen"],
                                         libraryAlbumKeys: ["queen|a night at the opera"])
        XCTAssertEqual(
            DiscoveryFilter.rejectReason(kind: .album, artist: "Queen", album: "A Night at the Opera",
                                         dedupKey: key(.album, "Queen", "A Night at the Opera"), score: 0.9, context: ctx),
            .inLibrary)
        XCTAssertNil(
            DiscoveryFilter.rejectReason(kind: .album, artist: "Queen", album: "Jazz",
                                         dedupKey: key(.album, "Queen", "Jazz"), score: 0.9, context: ctx))
    }

    func testListenedArtistDropsArtistKindOnly() {
        let ctx = DiscoveryFilterContext(listenedArtists: ["radiohead"])
        XCTAssertEqual(
            DiscoveryFilter.rejectReason(kind: .artist, artist: "Radiohead", album: nil,
                                         dedupKey: key(.artist, "Radiohead"), score: 0.9, context: ctx),
            .alreadyListened)
        // An unowned album by a listened artist is exactly what release-radar wants.
        XCTAssertNil(
            DiscoveryFilter.rejectReason(kind: .album, artist: "Radiohead", album: "In Rainbows",
                                         dedupKey: key(.album, "Radiohead", "In Rainbows"), score: 0.9, context: ctx))
    }

    func testPermanentBlock() {
        let k = key(.artist, "Nickelback")
        let ctx = DiscoveryFilterContext(rejections: [k: RejectionInfo(rejectedAt: nil, permanent: true)])
        XCTAssertEqual(
            DiscoveryFilter.rejectReason(kind: .artist, artist: "Nickelback", album: nil, dedupKey: k, score: 0.9, context: ctx),
            .blocked)
    }

    func testCooldownWindow() {
        let k = key(.artist, "Coldplay")
        let now = Date()
        let recent = DiscoveryFilterContext(rejections: [k: RejectionInfo(rejectedAt: now.addingTimeInterval(-10 * 86400), permanent: false)],
                                            cooldownDays: 60, now: now)
        XCTAssertEqual(
            DiscoveryFilter.rejectReason(kind: .artist, artist: "Coldplay", album: nil, dedupKey: k, score: 0.9, context: recent),
            .cooldown)
        // Past the window → allowed again.
        let old = DiscoveryFilterContext(rejections: [k: RejectionInfo(rejectedAt: now.addingTimeInterval(-70 * 86400), permanent: false)],
                                         cooldownDays: 60, now: now)
        XCTAssertNil(
            DiscoveryFilter.rejectReason(kind: .artist, artist: "Coldplay", album: nil, dedupKey: k, score: 0.9, context: old))
    }

    func testBelowThreshold() {
        let ctx = DiscoveryFilterContext(scoreThreshold: 0.35)
        XCTAssertEqual(
            DiscoveryFilter.rejectReason(kind: .artist, artist: "New Band", album: nil,
                                         dedupKey: key(.artist, "New Band"), score: 0.1, context: ctx),
            .belowThreshold)
    }

    func testKeepsAGoodFreshCandidate() {
        let ctx = DiscoveryFilterContext(libraryArtists: ["queen"], scoreThreshold: 0.35)
        XCTAssertTrue(
            DiscoveryFilter.keep(kind: .artist, artist: "Boards of Canada", album: nil,
                                 dedupKey: key(.artist, "Boards of Canada"), score: 0.72, context: ctx))
    }
}
