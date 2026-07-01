@testable import RoonSageCore
import XCTest

/// The pure "Ontdek-inzichten" aggregation: lifetime approval rate, per-producer
/// accept-rate (with the no-decisions-yet case), producer ordering, and the
/// genre trend with its accepted-else-all fallback.
final class DiscoveryStatsTests: XCTestCase {

    private func item(_ status: String, _ producers: [String],
                      _ genres: [String] = []) -> DiscoveryStatsBuilder.ItemFacts {
        .init(status: status, producers: producers, genres: genres)
    }

    func testEmptyInputsAreAllZero() {
        let s = DiscoveryStatsBuilder.build(items: [], lifetimeAccepted: 0, lifetimeRejected: 0,
                                            latestPending: 0, generatedAt: "t")
        XCTAssertEqual(s.accepted, 0)
        XCTAssertEqual(s.rejected, 0)
        XCTAssertEqual(s.pending, 0)
        XCTAssertEqual(s.approvalRate, 0, accuracy: 1e-9)
        XCTAssertTrue(s.producers.isEmpty)
        XCTAssertTrue(s.topGenres.isEmpty)
    }

    func testApprovalRateIsLifetimeAcceptFraction() {
        let s = DiscoveryStatsBuilder.build(items: [], lifetimeAccepted: 3, lifetimeRejected: 1,
                                            latestPending: 7, generatedAt: "t")
        XCTAssertEqual(s.approvalRate, 0.75, accuracy: 1e-9)
        XCTAssertEqual(s.pending, 7)
    }

    func testProducerAcceptRateAndNilWhenNoDecisions() {
        let items = [
            item("accepted", ["ai-picks"]),
            item("rejected", ["ai-picks"]),
            item("accepted", ["ai-picks"]),
            item("pending", ["charts"]),   // charts: surfaced but not yet judged
        ]
        let s = DiscoveryStatsBuilder.build(items: items, lifetimeAccepted: 2, lifetimeRejected: 1,
                                            latestPending: 0, generatedAt: "t")
        let ai = s.producers.first { $0.producer == "ai-picks" }
        XCTAssertEqual(ai?.contributions, 3)
        XCTAssertEqual(ai?.accepted, 2)
        XCTAssertEqual(ai?.rejected, 1)
        XCTAssertEqual(ai?.acceptRate ?? -1, 2.0 / 3.0, accuracy: 1e-9)

        let charts = s.producers.first { $0.producer == "charts" }
        XCTAssertEqual(charts?.contributions, 1)
        XCTAssertNil(charts?.acceptRate)
    }

    func testProducersSortRatedBeforeUnratedThenByRate() {
        let items = [
            item("accepted", ["a"]), item("accepted", ["a"]),   // a: 100%
            item("accepted", ["b"]), item("rejected", ["b"]),   // b: 50%
            item("pending", ["c"]),                             // c: no decisions
        ]
        let s = DiscoveryStatsBuilder.build(items: items, lifetimeAccepted: 3, lifetimeRejected: 1,
                                            latestPending: 0, generatedAt: "t")
        XCTAssertEqual(s.producers.map(\.producer), ["a", "b", "c"])
    }

    func testProducerCountedOncePerItem() {
        let s = DiscoveryStatsBuilder.build(items: [item("accepted", ["dup", "dup"])],
                                            lifetimeAccepted: 1, lifetimeRejected: 0,
                                            latestPending: 0, generatedAt: "t")
        XCTAssertEqual(s.producers.first?.contributions, 1)
        XCTAssertEqual(s.producers.first?.accepted, 1)
    }

    func testGenreTrendFromAcceptedItemsIgnoresRejected() {
        let items = [
            item("accepted", ["x"], ["Jazz", "Soul"]),
            item("accepted", ["x"], ["Jazz"]),
            item("rejected", ["x"], ["Metal"]),
        ]
        let s = DiscoveryStatsBuilder.build(items: items, lifetimeAccepted: 2, lifetimeRejected: 1,
                                            latestPending: 0, generatedAt: "t")
        XCTAssertEqual(s.topGenres.first?.genre, "jazz")
        XCTAssertEqual(s.topGenres.first?.count, 2)
        XCTAssertFalse(s.topGenres.contains { $0.genre == "metal" })
    }

    func testGenreTrendFallsBackToAllWhenNoAccepts() {
        let items = [
            item("pending", ["x"], ["Ambient"]),
            item("rejected", ["x"], ["Ambient"]),
        ]
        let s = DiscoveryStatsBuilder.build(items: items, lifetimeAccepted: 0, lifetimeRejected: 1,
                                            latestPending: 0, generatedAt: "t")
        XCTAssertEqual(s.topGenres.first?.genre, "ambient")
        XCTAssertEqual(s.topGenres.first?.count, 2)
    }
}
