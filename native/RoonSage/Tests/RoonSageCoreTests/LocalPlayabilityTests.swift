@testable import RoonSageCore
import XCTest

/// Covers the pure local-playability split that decides which library tracks can
/// play on this device (have an on-disk file / analysed features) vs. which are
/// streaming-only (Qobuz) and get filtered out.
final class LocalPlayabilityTests: XCTestCase {
    private func rec(_ title: String, _ artist: String) -> TrackRecord {
        TrackRecord(id: "k-\(title)", title: title, artist: artist)
    }

    func testPartitionSplitsByPlayableKeys() {
        let a = rec("Roygbiv", "Boards of Canada")
        let b = rec("Teardrop", "Massive Attack")
        let keyA = LocalPlayability.matchKey(for: a)
        let part = LocalPlayability.partition([a, b], playableKeys: [keyA])
        XCTAssertEqual(part.playable.map(\.title), ["Roygbiv"])
        XCTAssertEqual(part.blocked.map(\.title), ["Teardrop"])
    }

    func testEmptyKeysBlocksEverything() {
        let part = LocalPlayability.partition([rec("X", "Y"), rec("Z", "W")], playableKeys: [])
        XCTAssertTrue(part.playable.isEmpty)
        XCTAssertEqual(part.blocked.count, 2)
    }

    func testMatchKeyIsStableForSameArtistTitle() {
        // Album is intentionally excluded from the key, so two copies on
        // different albums resolve to the same playable key.
        let k1 = LocalPlayability.matchKey(for: TrackRecord(id: "1", title: "Roygbiv", artist: "Boards of Canada", album: "Music Has the Right"))
        let k2 = LocalPlayability.matchKey(for: TrackRecord(id: "2", title: "Roygbiv", artist: "Boards of Canada", album: "A Compilation"))
        XCTAssertEqual(k1, k2)
        XCTAssertFalse(k1.isEmpty)
    }

    func testSummaryFlags() {
        let all = LocalPlaybackSummary(requested: 3, playable: 3, blocked: 0, blockedExamples: [])
        XCTAssertTrue(all.allPlayable)
        XCTAssertFalse(all.nonePlayable)

        let none = LocalPlaybackSummary(requested: 3, playable: 0, blocked: 3, blockedExamples: ["a"])
        XCTAssertTrue(none.nonePlayable)
        XCTAssertFalse(none.allPlayable)

        let some = LocalPlaybackSummary(requested: 5, playable: 3, blocked: 2, blockedExamples: ["a", "b"])
        XCTAssertFalse(some.allPlayable)
        XCTAssertFalse(some.nonePlayable)
    }
}
