import AudioAnalysis
import XCTest

/// Pins the fuzzy fallback used when exact match_key equality fails — chiefly
/// the classical-truncation case. Looseness is bounded (same primary artist only,
/// threshold 0.85), so these guard both the hits and the must-not-match cases.
final class FuzzyMatchTests: XCTestCase {

    func testClassicalTruncationScoresFull() {
        // Roon's short title's tokens are a subset of the file tag's long form.
        XCTAssertEqual(FuzzyMatch.score("Symphony No. 5", "Symphony No. 5 in C Minor, Op. 67"), 1.0)
    }

    func testMinorExtraQualifierStillMatches() {
        // "Clair de Lune" ⊂ "Clair de Lune (from Suite Bergamasque)" after cleaning.
        XCTAssertGreaterThanOrEqual(FuzzyMatch.score("Clair de Lune", "Clair de Lune from Suite Bergamasque"), 0.85)
    }

    func testDifferentSongsDoNotMatch() {
        XCTAssertLessThan(FuzzyMatch.score("Peace of Mind", "More Than a Feeling"), 0.85)
    }

    func testSingleTokenRequiresExact() {
        // Lone common words must not over-match across distinct recordings.
        XCTAssertEqual(FuzzyMatch.score("Intro", "Interlude"), 0.0)
        XCTAssertEqual(FuzzyMatch.score("Lithium", "Lithium"), 1.0)
    }

    func testEmptyTitlesScoreZero() {
        XCTAssertEqual(FuzzyMatch.score("", "Anything"), 0.0)
        XCTAssertEqual(FuzzyMatch.score(nil, nil), 0.0)
    }

    func testCleaningAppliesBeforeTokenising() {
        // Track prefix + feat credit are stripped before comparison.
        XCTAssertEqual(FuzzyMatch.score("1-04 Stan (feat. Dido)", "Stan"), 1.0)
    }
}
