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

    // MARK: recency (smooth logistic decay — C1)

    func testRecencyLogisticDecay() {
        let now = utc(2026, 1, 1)
        // Just released → plateau near 1; future clamps to 1.
        XCTAssertEqual(DiscoveryScoring.recency(releaseDate: "2026-01-01", now: now), 1.0, accuracy: 0.02)
        XCTAssertEqual(DiscoveryScoring.recency(releaseDate: "2027-06-01", now: now), 1.0, accuracy: 1e-9)
        // ~18 months old = the logistic midpoint → ~0.5.
        XCTAssertEqual(DiscoveryScoring.recency(releaseDate: "2024-07-01", now: now), 0.5, accuracy: 0.05)
        // Old release: small but strictly positive (no hard cliff to exactly 0).
        let old = DiscoveryScoring.recency(releaseDate: "2019-01-01", now: now)
        XCTAssertLessThan(old, 0.05)
        XCTAssertGreaterThan(old, 0)
        // No signal.
        XCTAssertEqual(DiscoveryScoring.recency(releaseDate: nil, now: now), 0.5, accuracy: 1e-9)
        XCTAssertEqual(DiscoveryScoring.recency(releaseDate: "not-a-date", now: now), 0.5, accuracy: 1e-9)
    }

    func testRecencyIsMonotonicallyDecreasing() {
        let now = utc(2026, 1, 1)
        let dates = ["2025-12-01", "2025-06-01", "2024-06-01", "2022-06-01", "2018-06-01"]
        let vals = dates.map { DiscoveryScoring.recency(releaseDate: $0, now: now) }
        for (a, b) in zip(vals, vals.dropFirst()) { XCTAssertGreaterThan(a, b) }
    }

    // MARK: producer-reliability nudge (C3)

    func testProducerReliabilityNudgeDirectionAndBounds() {
        // Unknown producers → no change.
        XCTAssertEqual(DiscoveryScoring.producerReliabilityNudge(producers: ["x"], reliabilities: [:]), 0, accuracy: 1e-9)
        // A perfectly-accepted producer → +full weight; never-accepted → −full weight.
        XCTAssertEqual(DiscoveryScoring.producerReliabilityNudge(producers: ["ai"], reliabilities: ["ai": 1.0]),
                       DiscoveryScoring.producerReliabilityWeight, accuracy: 1e-9)
        XCTAssertEqual(DiscoveryScoring.producerReliabilityNudge(producers: ["ai"], reliabilities: ["ai": 0.0]),
                       -DiscoveryScoring.producerReliabilityWeight, accuracy: 1e-9)
        // 50% accept-rate is neutral; unknown producers are ignored in the mean.
        XCTAssertEqual(DiscoveryScoring.producerReliabilityNudge(producers: ["a", "b"], reliabilities: ["a": 0.5, "b": 0.5]), 0, accuracy: 1e-9)
        XCTAssertEqual(DiscoveryScoring.producerReliabilityNudge(producers: ["a", "unknown"], reliabilities: ["a": 1.0]),
                       DiscoveryScoring.producerReliabilityWeight, accuracy: 1e-9)
    }

    // MARK: popularity (C2)

    func testPopularityLogNormalisation() throws {
        XCTAssertNil(DiscoveryScoring.popularity(listeners: nil))
        XCTAssertEqual(try XCTUnwrap(DiscoveryScoring.popularity(listeners: 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(DiscoveryScoring.popularity(listeners: 1_000_000)), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(DiscoveryScoring.popularity(listeners: 1_000)), 0.5, accuracy: 1e-9)
        // Above 1M clamps to 1.
        XCTAssertEqual(try XCTUnwrap(DiscoveryScoring.popularity(listeners: 50_000_000)), 1.0, accuracy: 1e-9)
    }

    func testPopularityNudgeIsDialAware() {
        // "veilig" (t=0): a popular artist lifts, an obscure one trims.
        XCTAssertEqual(DiscoveryScoring.popularityNudge(popularity: 1.0, adventurousness: 0),
                       DiscoveryScoring.popularityModifierWeight, accuracy: 1e-9)
        XCTAssertEqual(DiscoveryScoring.popularityNudge(popularity: 0.0, adventurousness: 0),
                       -DiscoveryScoring.popularityModifierWeight, accuracy: 1e-9)
        // "avontuurlijk" (t=1): the preference inverts — obscure lifts.
        XCTAssertEqual(DiscoveryScoring.popularityNudge(popularity: 1.0, adventurousness: 1),
                       -DiscoveryScoring.popularityModifierWeight, accuracy: 1e-9)
        // Neutral popularity or no signal → no nudge.
        XCTAssertEqual(DiscoveryScoring.popularityNudge(popularity: 0.5, adventurousness: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(DiscoveryScoring.popularityNudge(popularity: nil, adventurousness: 0), 0, accuracy: 1e-9)
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

    // MARK: tuned weights (F11 "veilig ↔ avontuurlijk" dial)

    private func sum(_ w: ScoringWeights) -> Double {
        w.consensus + w.similarity + w.genreOverlap + w.aiConfidence + w.feedbackBoost + w.popularity
    }

    func testTunedWeightsAlwaysSumToOne() {
        for t in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(sum(ScoringWeights.tuned(adventurousness: t)), 1.0, accuracy: 1e-9, "t=\(t)")
        }
    }

    func testTunedWeightsClampOutOfRangeInput() {
        XCTAssertEqual(ScoringWeights.tuned(adventurousness: -5).consensus,
                       ScoringWeights.tuned(adventurousness: 0).consensus, accuracy: 1e-9)
        XCTAssertEqual(ScoringWeights.tuned(adventurousness: 5).consensus,
                       ScoringWeights.tuned(adventurousness: 1).consensus, accuracy: 1e-9)
    }

    func testSafeAnchorTrustsConsensusAndGenreOverSimilarityAndAI() {
        let safe = ScoringWeights.tuned(adventurousness: 0)
        XCTAssertEqual(safe.consensus, 0.40, accuracy: 1e-9)
        XCTAssertEqual(safe.genreOverlap, 0.30, accuracy: 1e-9)
        XCTAssertEqual(safe.aiConfidence, 0.05, accuracy: 1e-9)
        XCTAssertGreaterThan(safe.consensus, safe.aiConfidence)
    }

    func testBoldAnchorShiftsWeightToSimilarityAndAI() {
        let bold = ScoringWeights.tuned(adventurousness: 1)
        XCTAssertEqual(bold.similarity, 0.30, accuracy: 1e-9)
        XCTAssertEqual(bold.aiConfidence, 0.30, accuracy: 1e-9)
        XCTAssertEqual(bold.genreOverlap, 0.10, accuracy: 1e-9)
        XCTAssertGreaterThan(bold.aiConfidence, ScoringWeights.tuned(adventurousness: 0).aiConfidence)
    }

    func testTunedIsMonotonicBetweenAnchors() {
        // consensus strictly decreases and aiConfidence strictly increases as the
        // dial moves from "veilig" to "avontuurlijk" — no reversal in between.
        let steps = stride(from: 0.0, through: 1.0, by: 0.1).map { ScoringWeights.tuned(adventurousness: $0) }
        for (a, b) in zip(steps, steps.dropFirst()) {
            XCTAssertLessThanOrEqual(b.consensus, a.consensus + 1e-9)
            XCTAssertGreaterThanOrEqual(b.aiConfidence, a.aiConfidence - 1e-9)
        }
    }

    func testDefaultAdventurousnessStaysCloseToOldHardcodedDefault() {
        // The dial's neutral point (0.35, shared with the radio dial) shouldn't
        // wildly diverge from the pre-F11 hardcoded `.default` on day one.
        let atDefault = ScoringWeights.tuned(adventurousness: 0.35)
        let old = ScoringWeights.default
        XCTAssertEqual(atDefault.consensus, old.consensus, accuracy: 0.1)
        XCTAssertEqual(atDefault.similarity, old.similarity, accuracy: 0.1)
        XCTAssertEqual(atDefault.genreOverlap, old.genreOverlap, accuracy: 0.1)
        XCTAssertEqual(atDefault.aiConfidence, old.aiConfidence, accuracy: 0.1)
    }
}
