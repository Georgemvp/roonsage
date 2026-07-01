@testable import RoonSageCore
import XCTest

/// The pure Qobuz *album* match gate — the discovery analog of the track scorer.
/// Guards against saving/playing the wrong album (wrong artist, a live/karaoke
/// edition, or a different title) while still matching deluxe/expanded editions.
final class DiscoveryAlbumMatchTests: XCTestCase {

    private func score(_ qTitle: String, _ qArtist: String?, want: String, artist: String?) -> (accept: Bool, score: Int) {
        QobuzClient.scoreAlbumCandidate(qobuzTitle: qTitle, qobuzArtist: qArtist, wantAlbum: want, wantArtist: artist)
    }

    func testExactAlbumAndArtistAccepts() {
        XCTAssertTrue(score("A Night at the Opera", "Queen", want: "A Night at the Opera", artist: "Queen").accept)
    }

    func testWrongArtistRejected() {
        XCTAssertFalse(score("A Night at the Opera", "Some Tribute Band", want: "A Night at the Opera", artist: "Queen").accept)
    }

    func testLiveEditionRejected() {
        XCTAssertFalse(score("A Night at the Opera (Live)", "Queen", want: "A Night at the Opera", artist: "Queen").accept)
    }

    func testDifferentAlbumRejected() {
        XCTAssertFalse(score("Jazz", "Queen", want: "A Night at the Opera", artist: "Queen").accept)
    }

    func testDeluxeEditionStillMatches() {
        // A deluxe/expanded edition IS the album (still playable/saveable) — accept.
        XCTAssertTrue(score("A Night at the Opera (Deluxe Edition)", "Queen", want: "A Night at the Opera", artist: "Queen").accept)
    }

    func testExactRanksAboveSubstring() {
        // Exact title beats a merely-substring match, so resolveAlbum picks the
        // right release when both surface ("Kid A" vs the "Kid A Mnesia" compilation).
        let exact = score("Kid A", "Radiohead", want: "Kid A", artist: "Radiohead")
        let substring = score("Kid A Mnesia", "Radiohead", want: "Kid A", artist: "Radiohead")
        XCTAssertTrue(exact.accept)
        XCTAssertGreaterThan(exact.score, substring.score)
    }
}
