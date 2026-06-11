import AudioAnalysis
import XCTest

/// Locks the content-match-key behaviour that joins analyzer features ↔ library
/// tracks. The app (Roon-sourced metadata) and the analyzer (file tags) must
/// produce the SAME key for the same recording — these tests pin the divergence
/// cases that previously sank the join (track prefixes, feat credits, multi-artist).
final class TrackIdentityTests: XCTestCase {

    // MARK: primaryArtist

    func testPrimaryArtistPlainPassesThrough() {
        XCTAssertEqual(TrackIdentity.primaryArtist("Radiohead"), "Radiohead")
    }

    func testPrimaryArtistCutsFeat() {
        XCTAssertEqual(TrackIdentity.primaryArtist("Calvin Harris feat. Rihanna"), "Calvin Harris")
        XCTAssertEqual(TrackIdentity.primaryArtist("Eminem ft. Dido"), "Eminem")
        XCTAssertEqual(TrackIdentity.primaryArtist("Drake Featuring Rihanna"), "Drake")
    }

    func testPrimaryArtistTakesFirstOfJoinedList() {
        XCTAssertEqual(TrackIdentity.primaryArtist("Daft Punk, Pharrell Williams"), "Daft Punk")
        XCTAssertEqual(TrackIdentity.primaryArtist("A; B; C"), "A")
        XCTAssertEqual(TrackIdentity.primaryArtist("Jay-Z & Kanye West"), "Jay-Z")
    }

    func testPrimaryArtistEmpty() {
        XCTAssertEqual(TrackIdentity.primaryArtist(nil), "")
        XCTAssertEqual(TrackIdentity.primaryArtist(""), "")
    }

    // MARK: matchKey — the property that matters: app side == analyzer side

    /// Roon hides the featured artist on the artist AND in the title; the file
    /// tag keeps both. After the fix they must collapse to the same key.
    func testMatchKeyConvergesAcrossFeatCredits() {
        let roon = TrackIdentity.matchKey(artist: "Calvin Harris", album: "Motion", title: "This Is What You Came For")
        let file = TrackIdentity.matchKey(artist: "Calvin Harris feat. Rihanna", album: "Motion",
                                          title: "This Is What You Came For (feat. Rihanna)")
        XCTAssertEqual(roon, file)
    }

    /// Roon's album browse prepends a disc-track number the file tag lacks.
    func testMatchKeyIgnoresTrackPrefix() {
        let roon = TrackIdentity.matchKey(artist: "Boston", album: "Boston", title: "1-2 Peace of Mind")
        let file = TrackIdentity.matchKey(artist: "Boston", album: "Boston", title: "Peace of Mind")
        XCTAssertEqual(roon, file)
    }

    /// Version-meaningful parens are DIFFERENT recordings — must NOT merge.
    func testMatchKeyKeepsLiveAndRemixDistinct() {
        let studio = TrackIdentity.matchKey(artist: "Nirvana", album: "Nevermind", title: "Lithium")
        let live = TrackIdentity.matchKey(artist: "Nirvana", album: "Unplugged", title: "Lithium (Live)")
        XCTAssertNotEqual(studio, live)
    }

    /// Album is intentionally excluded (editions/box-sets diverge).
    func testMatchKeyIgnoresAlbum() {
        let original = TrackIdentity.matchKey(artist: "10cc", album: "10cc", title: "Rubber Bullets")
        let boxset = TrackIdentity.matchKey(artist: "10cc", album: "Classic Album Selection", title: "Rubber Bullets")
        XCTAssertEqual(original, boxset)
    }
}
