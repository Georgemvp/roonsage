import Foundation
import RoonProtocol

/// Wraps Roon transport control calls: playback, volume, seek, settings, grouping.
/// Serialised through the actor to prevent out-of-order WebSocket sends.
actor TransportService {

    private let transport: RoonTransport

    init(transport: RoonTransport) {
        self.transport = transport
    }

    // MARK: - Playback control

    enum Control: String {
        case play, pause, playpause, previous, next, stop
    }

    @discardableResult
    func control(_ action: Control, zoneID: String) async throws -> [String: Any] {
        try await transport.request(
            "\(RoonService.transport)/control",
            body: ["zone_id": zoneID, "control": action.rawValue]
        )
    }

    // MARK: - Volume

    @discardableResult
    func changeVolume(outputID: String, how: String = "absolute", value: Int) async throws -> [String: Any] {
        try await transport.request(
            "\(RoonService.transport)/change_volume",
            body: ["output_id": outputID, "how": how, "value": value]
        )
    }

    @discardableResult
    func mute(outputID: String, muted: Bool) async throws -> [String: Any] {
        try await transport.request(
            "\(RoonService.transport)/mute",
            body: ["output_id": outputID, "how": muted ? "mute" : "unmute"]
        )
    }

    // MARK: - Seek

    @discardableResult
    func seek(zoneID: String, how: String = "absolute", seconds: Double) async throws -> [String: Any] {
        try await transport.request(
            "\(RoonService.transport)/seek",
            body: ["zone_id": zoneID, "how": how, "seconds": seconds]
        )
    }

    // MARK: - Zone settings

    @discardableResult
    func setShuffle(zoneID: String, enabled: Bool) async throws -> [String: Any] {
        try await transport.request(
            "\(RoonService.transport)/change_settings",
            body: ["zone_id": zoneID, "shuffle": enabled]
        )
    }

    enum RepeatMode: String {
        case off = "disabled", loop, one = "loop_one"
    }

    @discardableResult
    func setRepeat(zoneID: String, mode: RepeatMode) async throws -> [String: Any] {
        try await transport.request(
            "\(RoonService.transport)/change_settings",
            body: ["zone_id": zoneID, "loop": mode.rawValue]
        )
    }

    // MARK: - Zone management

    @discardableResult
    func groupOutputs(outputIDs: [String]) async throws -> [String: Any] {
        try await transport.request(
            "\(RoonService.transport)/group_outputs",
            body: ["output_ids": outputIDs]
        )
    }

    @discardableResult
    func ungroupOutputs(outputIDs: [String]) async throws -> [String: Any] {
        try await transport.request(
            "\(RoonService.transport)/ungroup_outputs",
            body: ["output_ids": outputIDs]
        )
    }

    @discardableResult
    func transferZone(fromZoneID: String, toZoneID: String) async throws -> [String: Any] {
        try await transport.request(
            "\(RoonService.transport)/transfer_zone",
            body: ["from_zone_id": fromZoneID, "to_zone_id": toZoneID]
        )
    }
}
