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

    func control(_ action: Control, zoneID: String) async throws {
        try await transport.dispatch(
            "\(RoonService.transport)/control",
            body: ["zone_or_output_id": zoneID, "control": action.rawValue]
        )
    }

    /// Jump to a track in the zone's play queue.
    func playFromHere(zoneID: String, queueItemID: Int) async throws {
        try await transport.dispatch(
            "\(RoonService.transport)/play_from_here",
            body: ["zone_or_output_id": zoneID, "queue_item_id": queueItemID]
        )
    }

    // MARK: - Volume

    func changeVolume(outputID: String, how: String = "absolute", value: Int) async throws {
        try await transport.dispatch(
            "\(RoonService.transport)/change_volume",
            body: ["output_id": outputID, "how": how, "value": value]
        )
    }

    func mute(outputID: String, muted: Bool) async throws {
        try await transport.dispatch(
            "\(RoonService.transport)/mute",
            body: ["output_id": outputID, "how": muted ? "mute" : "unmute"]
        )
    }

    // MARK: - Seek

    func seek(zoneID: String, how: String = "absolute", seconds: Double) async throws {
        try await transport.dispatch(
            "\(RoonService.transport)/seek",
            body: ["zone_or_output_id": zoneID, "how": how, "seconds": seconds]
        )
    }

    // MARK: - Zone settings

    func setShuffle(zoneID: String, enabled: Bool) async throws {
        try await transport.dispatch(
            "\(RoonService.transport)/change_settings",
            body: ["zone_or_output_id": zoneID, "shuffle": enabled]
        )
    }

    enum RepeatMode: String {
        case off = "disabled", loop, one = "loop_one"
    }

    func setRepeat(zoneID: String, mode: RepeatMode) async throws {
        try await transport.dispatch(
            "\(RoonService.transport)/change_settings",
            body: ["zone_or_output_id": zoneID, "loop": mode.rawValue]
        )
    }

    // MARK: - Zone management

    func groupOutputs(outputIDs: [String]) async throws {
        try await transport.dispatch(
            "\(RoonService.transport)/group_outputs",
            body: ["output_ids": outputIDs]
        )
    }

    func ungroupOutputs(outputIDs: [String]) async throws {
        try await transport.dispatch(
            "\(RoonService.transport)/ungroup_outputs",
            body: ["output_ids": outputIDs]
        )
    }

    func transferZone(fromZoneID: String, toZoneID: String) async throws {
        try await transport.dispatch(
            "\(RoonService.transport)/transfer_zone",
            body: ["from_zone_or_output_id": fromZoneID, "to_zone_or_output_id": toZoneID]
        )
    }
}
