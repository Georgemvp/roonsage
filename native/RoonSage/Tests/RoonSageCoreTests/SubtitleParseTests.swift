@testable import RoonSageCore
import XCTest

/// The Roon `"Artist • Year • Genre"` subtitle parser is explicitly flagged as
/// fragile (CLAUDE.md). These pin down its behaviour on the messy real-world
/// shapes it has to survive.
final class SubtitleParseTests: XCTestCase {
    private func parse(_ s: String?) -> (artist: String?, year: Int?) {
        LibrarySyncService.parseSubtitle(s)
    }

    func testNilAndEmpty() {
        XCTAssertTrue(parse(nil) == (nil, nil))
        XCTAssertTrue(parse("") == (nil, nil))
    }

    func testFullArtistYearGenre() {
        let r = parse("Miles Davis • 1959 • Jazz")
        XCTAssertEqual(r.artist, "Miles Davis")
        XCTAssertEqual(r.year, 1959)
    }

    func testArtistOnly() {
        let r = parse("Radiohead")
        XCTAssertEqual(r.artist, "Radiohead")
        XCTAssertNil(r.year)
    }

    func testArtistAndYearNoGenre() {
        let r = parse("Aphex Twin • 1996")
        XCTAssertEqual(r.artist, "Aphex Twin")
        XCTAssertEqual(r.year, 1996)
    }

    func testYearWithSurroundingText() {
        // Roon sometimes decorates the year ("Released 2004", "2004 ·"); the
        // parser keeps only the digits.
        XCTAssertEqual(parse("Artist • Released 2004 • Rock").year, 2004)
        XCTAssertEqual(parse("Artist • ©1971").year, 1971)
    }

    func testWhitespaceTrimming() {
        let r = parse("  Bonobo   •   2017   •  Electronic ")
        XCTAssertEqual(r.artist, "Bonobo")
        XCTAssertEqual(r.year, 2017)
    }

    func testLeadingBulletGivesNoArtist() {
        // A leading separator means the first segment is empty → no artist.
        let r = parse(" • 1980 • Pop")
        XCTAssertNil(r.artist)
        XCTAssertEqual(r.year, 1980)
    }

    func testNonNumericYearSegmentIsNil() {
        XCTAssertNil(parse("Artist • Various • Jazz").year)
    }

    func testArtistNameWithDigitsIsNotMistakenForYear() {
        let r = parse("Sum 41 • 2001 • Punk")
        XCTAssertEqual(r.artist, "Sum 41")
        XCTAssertEqual(r.year, 2001)
    }
}
