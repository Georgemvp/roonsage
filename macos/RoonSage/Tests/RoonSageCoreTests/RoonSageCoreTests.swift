import XCTest
@testable import RoonSageCore

final class RoonSageCoreTests: XCTestCase {
    func testZoneFromDict() {
        let dict: [String: Any] = [
            "zone_id": "z1",
            "display_name": "Living Room",
            "state": "playing",
            "outputs": [],
        ]
        let zone = Zone(from: dict)
        XCTAssertEqual(zone.id, "z1")
        XCTAssertEqual(zone.displayName, "Living Room")
        XCTAssertEqual(zone.state, .playing)
    }
}
