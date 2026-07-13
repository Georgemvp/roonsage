import XCTest
@testable import RoonSageCore

final class DiscoverySonicFitTests: XCTestCase {
    private let w = DiscoverySonicFit.sonicFitWeight
    private let neutral = DiscoverySonicFit.neutralCosine

    func testNeutralCosineGivesNoNudge() {
        XCTAssertEqual(DiscoverySonicFit.nudge(cosine: neutral), 0, accuracy: 1e-9)
    }

    func testAboveNeutralLiftsBelowTrims() {
        XCTAssertGreaterThan(DiscoverySonicFit.nudge(cosine: neutral + 0.1), 0)
        XCTAssertLessThan(DiscoverySonicFit.nudge(cosine: neutral - 0.1), 0)
    }

    func testClampedToWeight() {
        // A cosine far above/below neutral saturates at exactly ±weight.
        XCTAssertEqual(DiscoverySonicFit.nudge(cosine: 1.0), w, accuracy: 1e-9)
        XCTAssertEqual(DiscoverySonicFit.nudge(cosine: -1.0), -w, accuracy: 1e-9)
        // Never exceeds the bound even at the theoretical cosine extreme.
        XCTAssertLessThanOrEqual(DiscoverySonicFit.nudge(cosine: 5.0), w)
        XCTAssertGreaterThanOrEqual(DiscoverySonicFit.nudge(cosine: -5.0), -w)
    }

    func testMonotonic() {
        let a = DiscoverySonicFit.nudge(cosine: 0.2)
        let b = DiscoverySonicFit.nudge(cosine: 0.4)
        let c = DiscoverySonicFit.nudge(cosine: 0.5)
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
    }
}
