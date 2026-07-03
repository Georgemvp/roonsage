import XCTest
@testable import AudioAnalysis

final class AuthThrottlerTests: XCTestCase {
    func testThrottlesAfterMaxConsecutiveFailures() {
        let t = AuthThrottler(maxFailures: 5, penalty: 3)
        let now = Date()
        for _ in 0..<4 { t.recordFailure("10.0.0.9", now: now) }
        XCTAssertFalse(t.isThrottled("10.0.0.9", now: now), "4 failures — still allowed")
        t.recordFailure("10.0.0.9", now: now)
        XCTAssertTrue(t.isThrottled("10.0.0.9", now: now), "5th failure trips the throttle")
        XCTAssertFalse(t.isThrottled("10.0.0.10", now: now), "other IPs unaffected")
    }

    func testPenaltyExpires() {
        let t = AuthThrottler(maxFailures: 2, penalty: 3)
        let now = Date()
        t.recordFailure("ip", now: now)
        t.recordFailure("ip", now: now)
        XCTAssertTrue(t.isThrottled("ip", now: now))
        XCTAssertFalse(t.isThrottled("ip", now: now.addingTimeInterval(3.5)),
                       "penalty window has passed")
    }

    func testSuccessClearsCounter() {
        let t = AuthThrottler(maxFailures: 2, penalty: 3)
        t.recordFailure("ip")
        t.recordSuccess("ip")
        t.recordFailure("ip")
        XCTAssertFalse(t.isThrottled("ip"), "success reset the consecutive count")
    }

    func testEntryCapEvictsStalest() {
        let t = AuthThrottler(maxFailures: 1, penalty: 60, maxEntries: 2)
        let now = Date()
        t.recordFailure("a", now: now)
        t.recordFailure("b", now: now.addingTimeInterval(1))
        t.recordFailure("c", now: now.addingTimeInterval(2))   // evicts "a"
        XCTAssertFalse(t.isThrottled("a", now: now.addingTimeInterval(3)))
        XCTAssertTrue(t.isThrottled("b", now: now.addingTimeInterval(3)))
        XCTAssertTrue(t.isThrottled("c", now: now.addingTimeInterval(3)))
    }

    func testEmptyIPNeverThrottles() {
        let t = AuthThrottler(maxFailures: 1, penalty: 60)
        t.recordFailure("")
        XCTAssertFalse(t.isThrottled(""))
    }
}
