@testable import AudioAnalysis
import XCTest

/// Year sanity: broken file tags (4018, 0, garbage) must yield NO year rather
/// than a wrong one — a 4018 tag once minted a ghost "decade:4010" radio.
final class MetadataYearTests: XCTestCase {
    func testPlausibleYearsPass() {
        XCTAssertEqual(MetadataReader.saneYear("1969"), 1969)
        XCTAssertEqual(MetadataReader.saneYear("2026-07-19"), 2026, "date strings use the year prefix")
        XCTAssertEqual(MetadataReader.saneYear("1900"), 1900)
    }

    func testImplausibleYearsAreDropped() {
        XCTAssertNil(MetadataReader.saneYear("4018"))
        XCTAssertNil(MetadataReader.saneYear("0"))
        XCTAssertNil(MetadataReader.saneYear("1773"))
        XCTAssertNil(MetadataReader.saneYear("197"), "three digits is not a year")
        XCTAssertNil(MetadataReader.saneYear(nil))
        XCTAssertNil(MetadataReader.saneYear("unknown"))
    }
}
