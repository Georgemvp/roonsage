@testable import RoonSageCore
import XCTest

/// The pure, network-free heart of Qobuz track matching: candidate scoring,
/// the acceptance signals (title agreement + artist confirmation), version
/// penalties, tiered queries and id dedup. These guard the property that a
/// curated playlist resolves to the RIGHT Qobuz tracks (not covers / karaoke /
/// wrong-artist) and doesn't silently duplicate.
final class QobuzClientTests: XCTestCase {

    private func score(_ qTitle: String, _ qPerf: String?, _ qAlbum: String?,
                       want: String, artist: String?, album: String? = nil)
        -> (total: Int, titleScore: Int, artistConfirmed: Bool, artistExact: Bool, albumConfirmed: Bool) {
        QobuzClient.scoreCandidate(
            qobuzTitle: qTitle, qobuzPerformer: qPerf, qobuzAlbum: qAlbum,
            wantTitle: want, wantArtist: artist, wantAlbum: album)
    }

    // MARK: scoring + acceptance

    func testExactTitleAndArtistConfirms() {
        let s = score("Bohemian Rhapsody", "Queen", "A Night at the Opera",
                      want: "Bohemian Rhapsody", artist: "Queen")
        XCTAssertEqual(s.titleScore, 4)
        XCTAssertTrue(s.artistConfirmed)
        XCTAssertGreaterThanOrEqual(s.total, 7)
    }

    func testSameTitleDifferentArtistNotConfirmed() {
        // "Cry Me a River" by the wrong artist must NOT confirm the artist.
        let s = score("Cry Me a River", "Susan Boyle", nil,
                      want: "Cry Me a River", artist: "Justin Timberlake")
        XCTAssertEqual(s.titleScore, 4, "title still matches")
        XCTAssertFalse(s.artistConfirmed, "different artist is not confirmed → caller rejects")
    }

    func testDiacriticAndSeparatorNormalization() {
        // Roon 'Björk' vs Qobuz 'Bjork'; '&' folds to a space on both sides.
        let s = score("Jóga", "Björk", nil, want: "Joga", artist: "Bjork")
        XCTAssertTrue(s.artistConfirmed)
        XCTAssertGreaterThanOrEqual(s.titleScore, 1)
    }

    func testFeatCreditIgnoredInTitleMatch() {
        // Qobuz lists the feat credit, our library title doesn't (or vice versa).
        let s = score("Get Lucky (feat. Pharrell Williams)", "Daft Punk", nil,
                      want: "Get Lucky", artist: "Daft Punk")
        XCTAssertEqual(s.titleScore, 4, "feat credit is stripped before comparing")
        XCTAssertTrue(s.artistConfirmed)
    }

    func testKaraokeVersionPenalisedBelowStudio() {
        let studio = score("Imagine", "John Lennon", "Imagine",
                           want: "Imagine", artist: "John Lennon")
        let karaoke = score("Imagine (Karaoke Version)", "John Lennon", "Karaoke Hits",
                            want: "Imagine", artist: "John Lennon")
        XCTAssertGreaterThan(studio.total, karaoke.total, "studio outranks karaoke")
    }

    func testLiveVersionPenalisedUnlessRequested() {
        let studio = score("Money", "Pink Floyd", nil, want: "Money", artist: "Pink Floyd")
        let live = score("Money (Live)", "Pink Floyd", nil, want: "Money", artist: "Pink Floyd")
        XCTAssertGreaterThan(studio.total, live.total)
        // But if the user's own track IS the live one, no penalty disadvantage.
        let wantLive = score("Money (Live)", "Pink Floyd", nil, want: "Money (Live)", artist: "Pink Floyd")
        XCTAssertEqual(QobuzClient.versionPenalty(candidateTitle: "Money (Live)", wantTitle: "Money (Live)"), 0)
        XCTAssertGreaterThanOrEqual(wantLive.total, live.total)
    }

    func testVersionPenaltyWordBoundary() {
        // "live" inside "Olive" / "Delivery" must not trigger a live penalty.
        XCTAssertEqual(QobuzClient.versionPenalty(candidateTitle: "Olive Branch", wantTitle: "Olive Branch"), 0)
        XCTAssertEqual(QobuzClient.versionPenalty(candidateTitle: "Special Delivery", wantTitle: "Special Delivery"), 0)
        XCTAssertGreaterThan(QobuzClient.versionPenalty(candidateTitle: "Song (Live)", wantTitle: "Song"), 0)
    }

    func testAlbumBonusIsSoftTiebreak() {
        let withAlbum = score("Yesterday", "The Beatles", "Help!",
                              want: "Yesterday", artist: "The Beatles", album: "Help!")
        let noAlbum = score("Yesterday", "The Beatles", "Love Songs Compilation",
                            want: "Yesterday", artist: "The Beatles", album: "Help!")
        XCTAssertGreaterThan(withAlbum.total, noAlbum.total, "matching album breaks a tie upward")
    }

    func testUnrelatedTitleScoresZero() {
        let s = score("Bohemian Grove", "Some Band", nil,
                      want: "Bohemian Rhapsody", artist: "Queen")
        XCTAssertEqual(s.titleScore, 0, "partial word overlap is not a title match")
    }

    // MARK: non-latin scripts (must not fold to empty → drop)

    func testCyrillicExactMatchResolves() {
        let s = score("Кино", "Виктор Цой", nil, want: "Кино", artist: "Виктор Цой")
        XCTAssertEqual(s.titleScore, 4, "Cyrillic title compares on raw glyphs, not empty ASCII")
        XCTAssertTrue(s.artistConfirmed)
    }

    func testJapaneseExactTitleResolves() {
        let s = score("見上げてごらん夜の星を", "坂本九", nil,
                      want: "見上げてごらん夜の星を", artist: "坂本九")
        XCTAssertEqual(s.titleScore, 4)
        XCTAssertTrue(s.artistConfirmed)
    }

    func testNonLatinWrongTitleStillRejected() {
        let s = score("Кино", "Виктор Цой", nil, want: "Группа крови", artist: "Виктор Цой")
        XCTAssertEqual(s.titleScore, 0, "different non-latin titles do not match")
    }

    // MARK: tribute / wrong-artist guards

    func testTributePerformerScoresBelowReal() {
        let real = score("Yesterday", "The Beatles", "Help!", want: "Yesterday", artist: "The Beatles")
        let tribute = score("Yesterday", "The Beatles Tribute Band", "Tribute Hits",
                            want: "Yesterday", artist: "The Beatles")
        XCTAssertGreaterThan(real.total, tribute.total, "a tribute-band performer is penalised")
    }

    func testSharedFirstTokenDoesNotFalseConfirm() {
        // "Simon & Garfunkel" reduces to "simon"; must NOT confirm against "Simon Says".
        let s = score("Song", "Simon Says", nil, want: "Song", artist: "Simon & Garfunkel")
        XCTAssertFalse(s.artistConfirmed, "a single short shared token is not artist confirmation")
    }

    func testLongerSubstringArtistStillConfirms() {
        // "Beyoncé" vs "Beyoncé Knowles" — substantial substring, must still confirm.
        let s = score("Halo", "Beyoncé Knowles", nil, want: "Halo", artist: "Beyoncé")
        XCTAssertTrue(s.artistConfirmed)
        XCTAssertFalse(s.artistExact)
    }

    func testShortAlbumDoesNotFalseBonus() {
        // Album "1" must not substring-match an unrelated "1 (Remastered) Hits".
        let s = score("Come Together", "The Beatles", "1 Greatest Hits Collection",
                      want: "Come Together", artist: "The Beatles", album: "1")
        XCTAssertFalse(s.albumConfirmed, "a 1-char album is too short for a substring bonus")
    }

    // MARK: classical / compilation recovery signal

    func testClassicalComposerAlbumConfirmsForRecovery() {
        // Roon artist = composer; Qobuz performer = orchestra. Artist not confirmed,
        // but exact title + matching album make it a safe recovery candidate.
        let s = score("Symphony No. 9", "Berliner Philharmoniker", "Beethoven: Symphony No. 9",
                      want: "Symphony No. 9", artist: "Beethoven", album: "Beethoven: Symphony No. 9")
        XCTAssertEqual(s.titleScore, 4)
        XCTAssertFalse(s.artistConfirmed, "orchestra ≠ composer")
        XCTAssertTrue(s.albumConfirmed, "album matches → resolveTrackID can recover it")
    }

    // MARK: queries

    func testCandidateQueriesWidenAndDedupe() {
        let qs = QobuzClient.candidateQueries(title: "Get Lucky (feat. Pharrell)", artist: "Daft Punk")
        XCTAssertEqual(qs.first, "Daft Punk Get Lucky (feat. Pharrell)", "tier 1 keeps the exact strings")
        XCTAssertTrue(qs.contains("Daft Punk Get Lucky"), "tier 2 cleans feat noise")
        XCTAssertTrue(qs.contains("Get Lucky"), "tier 3 is title-only")
        XCTAssertEqual(qs.count, Set(qs).count, "no duplicate queries")
    }

    func testCandidateQueriesNilArtist() {
        let qs = QobuzClient.candidateQueries(title: "Clocks", artist: nil)
        XCTAssertFalse(qs.isEmpty)
        XCTAssertTrue(qs.contains("Clocks"))
    }

    // MARK: dedup

    func testDedupePreservesOrder() {
        XCTAssertEqual(QobuzClient.dedupePreservingOrder([3, 1, 3, 2, 1, 4]), [3, 1, 2, 4])
        XCTAssertEqual(QobuzClient.dedupePreservingOrder([]), [])
        XCTAssertEqual(QobuzClient.dedupePreservingOrder([9, 9, 9]), [9])
    }
}
