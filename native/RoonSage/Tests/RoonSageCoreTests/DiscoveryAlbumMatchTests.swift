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

    // MARK: Loosened credited-artist matching

    func testCollaborationCreditConfirmsNonLeadingArtist() {
        // Qobuz lists the album under the leading collaborator; the recommendation
        // came in under the other member. Same album — accept.
        XCTAssertTrue(score("My Life in the Bush of Ghosts", "David Byrne & Brian Eno",
                            want: "My Life in the Bush of Ghosts", artist: "Brian Eno").accept)
    }

    func testFeatCreditConfirmsGuestArtist() {
        XCTAssertTrue(score("Watch the Throne", "Jay-Z feat. Kanye West",
                            want: "Watch the Throne", artist: "Kanye West").accept)
    }

    func testCommaCreditConfirmsMember() {
        XCTAssertTrue(score("River: The Joni Letters", "Herbie Hancock, Wayne Shorter",
                            want: "River: The Joni Letters", artist: "Wayne Shorter").accept)
    }

    func testCreditedMatchStillNeedsTitle() {
        // A shared collaborator must NOT confirm a DIFFERENT album.
        XCTAssertFalse(score("Remain in Light", "David Byrne & Brian Eno",
                             want: "My Life in the Bush of Ghosts", artist: "Brian Eno").accept)
    }

    func testUnrelatedArtistStillRejectedDespiteSharedTitle() {
        // Same album title, genuinely different artist (not a credited member) — reject.
        XCTAssertFalse(score("Greatest Hits", "Some Other Band",
                             want: "Greatest Hits", artist: "Queen").accept)
    }
}
