import AudioAnalysis
import Foundation
import Observation
import RoonProtocol

@MainActor
extension RoonClient {
    // MARK: - Transport controls (exposed to UI)

    public func playPause(zoneID: String) async {
        _ = try? await transportService?.control(.playpause, zoneID: zoneID)
    }

    public func next(zoneID: String) async {
        _ = try? await transportService?.control(.next, zoneID: zoneID)
    }

    public func previous(zoneID: String) async {
        _ = try? await transportService?.control(.previous, zoneID: zoneID)
    }

    public func setVolume(outputID: String, value: Int) async {
        _ = try? await transportService?.changeVolume(outputID: outputID, how: "absolute", value: value)
    }

    public func seek(zoneID: String, seconds: Double) async {
        _ = try? await transportService?.seek(zoneID: zoneID, how: "absolute", seconds: seconds)
    }

    public func adjustVolume(outputID: String, delta: Int) async {
        _ = try? await transportService?.changeVolume(outputID: outputID, how: "relative", value: delta)
    }

    public func toggleMute(outputID: String, muted: Bool) async {
        _ = try? await transportService?.mute(outputID: outputID, muted: muted)
    }

    public func setShuffle(zoneID: String, enabled: Bool) async {
        _ = try? await transportService?.setShuffle(zoneID: zoneID, enabled: enabled)
    }

    public func setRepeat(zoneID: String, mode: String) async {
        let rMode = TransportService.RepeatMode(rawValue: mode) ?? .off
        _ = try? await transportService?.setRepeat(zoneID: zoneID, mode: rMode)
    }

    /// Play a list of tracks by their Roon item_keys using the browse API.
    /// First track plays immediately; subsequent tracks are queued.
    public func curateTracks(_ tracks: [TrackRecord], zoneID: String) async {
        guard let browse = browseService else { return }
        var isFirst = true
        for track in tracks {
            try? await browse.playByBrowse(itemKey: track.id, zoneID: zoneID, action: isFirst ? "play_now" : "queue")
            isFirst = false
        }
    }

}
