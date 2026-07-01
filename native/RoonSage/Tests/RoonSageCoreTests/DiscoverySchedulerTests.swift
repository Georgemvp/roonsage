@testable import RoonSageCore
import XCTest

/// The scheduler's cost-control guard: a stable, order-independent taste
/// signature, and the pure skip-if-unchanged decision (no clock/DB reads, so
/// every edge case is directly testable).
final class DiscoverySchedulerTests: XCTestCase {

    // MARK: tasteSignature

    func testTasteSignatureStableAndOrderIndependent() {
        let a = DiscoveryPipeline.tasteSignature(
            topArtists: ["Radiohead", "Bjork"], liked: ["Aphex Twin"], disliked: [], watchlist: ["boards of canada"])
        let b = DiscoveryPipeline.tasteSignature(
            topArtists: ["Bjork", "Radiohead"], liked: ["Aphex Twin"], disliked: [], watchlist: ["Boards Of Canada"])
        XCTAssertEqual(a, b)   // reordering + case differences don't change it
    }

    func testTasteSignatureChangesOnNewLike() {
        let a = DiscoveryPipeline.tasteSignature(topArtists: ["Radiohead"], liked: [], disliked: [], watchlist: [])
        let b = DiscoveryPipeline.tasteSignature(topArtists: ["Radiohead"], liked: ["Aphex Twin"], disliked: [], watchlist: [])
        XCTAssertNotEqual(a, b)
    }

    func testTasteSignatureChangesOnNewWatchlistArtist() {
        let a = DiscoveryPipeline.tasteSignature(topArtists: [], liked: [], disliked: [], watchlist: ["radiohead"])
        let b = DiscoveryPipeline.tasteSignature(topArtists: [], liked: [], disliked: [], watchlist: ["radiohead", "bjork"])
        XCTAssertNotEqual(a, b)
    }

    // MARK: shouldSkipRun

    func testNoSkipWithoutAPriorBatch() {
        XCTAssertFalse(DiscoveryPipeline.shouldSkipRun(
            trigger: "manual", tasteSig: "abc", lastBatchSig: nil, lastBatchCreatedAt: nil, now: Date()))
    }

    func testNoSkipWhenTasteChanged() {
        let now = Date()
        XCTAssertFalse(DiscoveryPipeline.shouldSkipRun(
            trigger: "manual", tasteSig: "new-sig", lastBatchSig: "old-sig",
            lastBatchCreatedAt: now.addingTimeInterval(-60), now: now))
    }

    func testManualSkipsWithinThirtyMinutesWhenUnchanged() {
        let now = Date()
        XCTAssertTrue(DiscoveryPipeline.shouldSkipRun(
            trigger: "manual", tasteSig: "same", lastBatchSig: "same",
            lastBatchCreatedAt: now.addingTimeInterval(-10 * 60), now: now))
    }

    func testManualDoesNotSkipPastThirtyMinutes() {
        let now = Date()
        XCTAssertFalse(DiscoveryPipeline.shouldSkipRun(
            trigger: "manual", tasteSig: "same", lastBatchSig: "same",
            lastBatchCreatedAt: now.addingTimeInterval(-40 * 60), now: now))
    }

    func testScheduledToleratesALongerWindowThanManual() {
        let now = Date()
        let anHourAgo = now.addingTimeInterval(-60 * 60)
        // Same age: manual would already allow a re-run (past its 30-min window),
        // but scheduled still skips (within its 6h window) — different thresholds.
        XCTAssertFalse(DiscoveryPipeline.shouldSkipRun(
            trigger: "manual", tasteSig: "same", lastBatchSig: "same", lastBatchCreatedAt: anHourAgo, now: now))
        XCTAssertTrue(DiscoveryPipeline.shouldSkipRun(
            trigger: "scheduled", tasteSig: "same", lastBatchSig: "same", lastBatchCreatedAt: anHourAgo, now: now))
    }

    func testScheduledDoesNotSkipPastSixHours() {
        let now = Date()
        XCTAssertFalse(DiscoveryPipeline.shouldSkipRun(
            trigger: "scheduled", tasteSig: "same", lastBatchSig: "same",
            lastBatchCreatedAt: now.addingTimeInterval(-7 * 60 * 60), now: now))
    }

    func testNegativeAgeNeverSkips() {
        // Defensive: a clock-skewed "future" timestamp must not be treated as fresh.
        let now = Date()
        XCTAssertFalse(DiscoveryPipeline.shouldSkipRun(
            trigger: "manual", tasteSig: "same", lastBatchSig: "same",
            lastBatchCreatedAt: now.addingTimeInterval(120), now: now))
    }
}
