import Foundation
import RoonProtocol
import XCTest
@testable import RoonSageCore

/// Records every dispatch so a test can assert the exact endpoint + body a
/// transport command sends — without a live WebSocket. The command-building is
/// worth pinning: a wrong body key (`output_id` vs `zone_or_output_id`) or a
/// mis-mapped enum string silently no-ops against Roon.
private actor MockTransport: TransportDispatching {
    private(set) var calls: [(endpoint: String, body: [String: Any]?)] = []
    var last: (endpoint: String, body: [String: Any]?)? { calls.last }
    func dispatch(_ endpoint: String, body: [String: Any]?) async throws {
        calls.append((endpoint, body))
    }
}

final class TransportServiceTests: XCTestCase {
    private let base = RoonService.transport

    func testControlSendsControlEndpointAndZoneAndAction() async throws {
        let mock = MockTransport()
        try await TransportService(transport: mock).control(.playpause, zoneID: "z1")
        let last = await mock.last
        XCTAssertEqual(last?.endpoint, "\(base)/control")
        XCTAssertEqual(last?.body?["zone_or_output_id"] as? String, "z1")
        XCTAssertEqual(last?.body?["control"] as? String, "playpause")
    }

    func testChangeVolumeUsesOutputIdAndDefaultsToAbsolute() async throws {
        let mock = MockTransport()
        try await TransportService(transport: mock).changeVolume(outputID: "o9", value: 42)
        let last = await mock.last
        XCTAssertEqual(last?.endpoint, "\(base)/change_volume")
        XCTAssertEqual(last?.body?["output_id"] as? String, "o9")
        XCTAssertEqual(last?.body?["how"] as? String, "absolute")
        XCTAssertEqual(last?.body?["value"] as? Int, 42)
    }

    func testMuteMapsBoolToHowString() async throws {
        let mock = MockTransport()
        let svc = TransportService(transport: mock)
        try await svc.mute(outputID: "o1", muted: true)
        var how = await mock.last?.body?["how"] as? String
        XCTAssertEqual(how, "mute")
        try await svc.mute(outputID: "o1", muted: false)
        how = await mock.last?.body?["how"] as? String
        XCTAssertEqual(how, "unmute")
    }

    func testRepeatModeMapsToRoonLoopStrings() async throws {
        let mock = MockTransport()
        let svc = TransportService(transport: mock)
        try await svc.setRepeat(zoneID: "z", mode: .one)
        var last = await mock.last
        XCTAssertEqual(last?.endpoint, "\(base)/change_settings")
        XCTAssertEqual(last?.body?["loop"] as? String, "loop_one")
        try await svc.setRepeat(zoneID: "z", mode: .off)
        last = await mock.last
        XCTAssertEqual(last?.body?["loop"] as? String, "disabled")
    }

    func testShuffleAndSeekAndGroupingPayloads() async throws {
        let mock = MockTransport()
        let svc = TransportService(transport: mock)

        try await svc.setShuffle(zoneID: "z", enabled: true)
        let shuffle = await mock.last?.body?["shuffle"] as? Bool
        XCTAssertEqual(shuffle, true)

        try await svc.seek(zoneID: "z", seconds: 12.5)
        var last = await mock.last
        XCTAssertEqual(last?.endpoint, "\(base)/seek")
        XCTAssertEqual(last?.body?["seconds"] as? Double, 12.5)

        try await svc.groupOutputs(outputIDs: ["a", "b"])
        last = await mock.last
        XCTAssertEqual(last?.endpoint, "\(base)/group_outputs")
        XCTAssertEqual(last?.body?["output_ids"] as? [String], ["a", "b"])

        try await svc.transferZone(fromZoneID: "from", toZoneID: "to")
        last = await mock.last
        XCTAssertEqual(last?.endpoint, "\(base)/transfer_zone")
        XCTAssertEqual(last?.body?["from_zone_or_output_id"] as? String, "from")
        XCTAssertEqual(last?.body?["to_zone_or_output_id"] as? String, "to")
    }
}
