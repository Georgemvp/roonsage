@testable import RoonSageCore
import XCTest

/// The pure "new releases since last seen" diff that keeps Release-Radar from
/// re-surfacing an artist's whole back-catalogue as "new" — the newest-first
/// list is walked only up to the previously-seen release-group.
final class ReleaseRadarLogicTests: XCTestCase {

    private func rg(_ mbid: String, _ title: String, _ date: String) -> MusicBrainzDiscoveryClient.MBReleaseGroup {
        MusicBrainzDiscoveryClient.MBReleaseGroup(mbid: mbid, title: title, primaryType: "Album", firstReleaseDate: date)
    }

    func testNeverScannedReturnsOnlyNewestRelease() {
        let albums = [rg("c", "Album C", "2026-01-01"), rg("b", "Album B", "2024-01-01"), rg("a", "Album A", "2020-01-01")]
        let fresh = ReleaseRadarProducer.newReleasesSinceSeen(sortedByDateDesc: albums, lastSeen: nil)
        XCTAssertEqual(fresh.map(\.mbid), ["c"])
    }

    func testReturnsEverythingNewerThanLastSeen() {
        let albums = [rg("c", "Album C", "2026-01-01"), rg("b", "Album B", "2024-01-01"), rg("a", "Album A", "2020-01-01")]
        let fresh = ReleaseRadarProducer.newReleasesSinceSeen(sortedByDateDesc: albums, lastSeen: "b")
        XCTAssertEqual(fresh.map(\.mbid), ["c"])
    }

    func testNoNewReleasesWhenLastSeenIsNewest() {
        let albums = [rg("c", "Album C", "2026-01-01"), rg("b", "Album B", "2024-01-01")]
        let fresh = ReleaseRadarProducer.newReleasesSinceSeen(sortedByDateDesc: albums, lastSeen: "c")
        XCTAssertTrue(fresh.isEmpty)
    }

    func testUnknownLastSeenFallsBackToNewestOnly() {
        // MB data drifted (e.g. a release-group was merged/deleted) — don't dump
        // the whole discography; treat it like a fresh watch.
        let albums = [rg("c", "Album C", "2026-01-01"), rg("b", "Album B", "2024-01-01")]
        let fresh = ReleaseRadarProducer.newReleasesSinceSeen(sortedByDateDesc: albums, lastSeen: "stale-deleted-rg")
        XCTAssertEqual(fresh.map(\.mbid), ["c"])
    }

    func testEmptyDiscographyReturnsEmpty() {
        XCTAssertTrue(ReleaseRadarProducer.newReleasesSinceSeen(sortedByDateDesc: [], lastSeen: nil).isEmpty)
    }
}
