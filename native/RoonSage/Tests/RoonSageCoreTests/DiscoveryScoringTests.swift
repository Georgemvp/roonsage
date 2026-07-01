@testable import RoonSageCore
import XCTest

/// The pure discovery scoring: the weighted composite, each component, recency
/// decay and the bounded album modifier. Guards the property that scores stay in
/// [0,1] and match digarr's formula.
final class DiscoveryScoringTests: XCTestCase {

    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    // MARK: consensus

    func testConsensusCapsAtFourSources() {
        XCTAssertEqual(DiscoveryScoring.consensus(distinctSources: 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(DiscoveryScoring.consensus(distinctSources: 4), 1.0, accuracy: 1e-9)
        XCTAssertEqual(DiscoveryScoring.consensus(distinctSources: 8), 1.0, accuracy: 1e-9)  // capped
        XCTAssertEqual(DiscoveryScoring.consensus(distinctSources: 0), 0.0, accuracy: 1e-9)
    }

    // MARK: genre overlap

    func testGenreOverlapFraction() {
        let lib: Set<String> = ["rock", "blues"]
        XCTAssertEqual(DiscoveryScoring.genreOverlap(candidateGenres: ["Rock", "Pop"], libraryGenres: lib), 0.5, accuracy: 1e-9)
        XCTAssertEqual(DiscoveryScoring.genreOverlap(candidateGenres: ["jazz"], libraryGenres: lib), 0.0, accuracy: 1e-9)
        XCTAssertEqual(DiscoveryScoring.genreOverlap(candidateGenres: [], libraryGenres: lib), 0.0, accuracy: 1e-9)
    }

    // MARK: feedback boost

    func testFeedbackBoostDefaultsToNeutral() {
        XCTAssertEqual(DiscoveryScoring.feedbackBoost(candidateGenres: ["rock"], rates: [:]), 0.5, accuracy: 1e-9)
        XCTAssertEqual(DiscoveryScoring.feedbackBoost(candidateGenres: [], rates: [:]), 0.5, accuracy: 1e-9)
    }

    func testFeedbackBoostStrongNegativePenalty() {
        // A genre approved 0% with all-strong-negative rejections drops below a
        // plain approve-rate (which would already be 0 here, so it stays 0).
        let disliked = ["rock": (approve: 0.0, strongNeg: 1.0)]
        XCTAssertEqual(DiscoveryScoring.feedbackBoost(candidateGenres: ["rock"], rates: disliked), 0.0, accuracy: 1e-9)
        // A 50%-approved genre with half strong-negative: 0.5 * (1 - 0.5*0.5) = 0.375.
        let mixed = ["rock": (approve: 0.5, strongNeg: 0.5)]
        XCTAssertEqual(DiscoveryScoring.feedbackBoost(candidateGenres: ["rock"], rates: mixed), 0.375, accuracy: 1e-9)
    }

    // MARK: weighted composite

    func testWeightsSumToOneAndClamp() {
        var all1 = ScoreComponents()
        all1.consensus = 1; all1.similarity = 1; all1.genreOverlap = 1
        all1.aiConfidence = 1; all1.feedbackBoost = 1; all1.popularity = 1
        XCTAssertEqual(DiscoveryScoring.weightedScore(.default, all1), 1.0, accuracy: 1e-9)
        XCTAssertEqual(DiscoveryScoring.weightedScore(.default, ScoreComponents()), 0.0, accuracy: 1e-9)
    }

    // MARK: recency

    func testRecencyLinearDecay() {
        let now = utc(2026, 1, 1)
        XCTAssertEqual(DiscoveryScoring.recency(releaseDate: "2026-01-01", now: now), 1.0, accuracy: 0.02)
        XCTAssertEqual(DiscoveryScoring.recency(releaseDate: "2019-01-01", now: now), 0.0, accuracy: 1e-9)  // >24mo
        XCTAssertEqual(DiscoveryScoring.recency(releaseDate: "2025-01-01", now: now), 0.5, accuracy: 0.03)  // ~12mo
        XCTAssertEqual(DiscoveryScoring.recency(releaseDate: nil, now: now), 0.5, accuracy: 1e-9)
        XCTAssertEqual(DiscoveryScoring.recency(releaseDate: "not-a-date", now: now), 0.5, accuracy: 1e-9)
    }

    // MARK: album modifier

    func testAlbumModifierBoundsAndDirection() {
        // All signals high → +0.15; all low → −0.15; none → unchanged.
        XCTAssertEqual(DiscoveryScoring.applyAlbumModifier(base: 0.5, recency: 1, popularity: 1, gapPriority: 1), 0.65, accuracy: 1e-9)
        XCTAssertEqual(DiscoveryScoring.applyAlbumModifier(base: 0.5, recency: 0, popularity: 0, gapPriority: 0), 0.35, accuracy: 1e-9)
        XCTAssertEqual(DiscoveryScoring.applyAlbumModifier(base: 0.5, recency: nil, popularity: nil, gapPriority: nil), 0.5, accuracy: 1e-9)
        // Clamped to [0,1].
        XCTAssertEqual(DiscoveryScoring.applyAlbumModifier(base: 0.95, recency: 1, popularity: 1, gapPriority: 1), 1.0, accuracy: 1e-9)
    }
}
