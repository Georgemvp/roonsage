import AudioAnalysis
import Foundation
import Observation
import RoonProtocol

@MainActor
extension RoonClient {
    // MARK: - Transport controls (exposed to UI)
    //
    // All commands route through `runAction` so failures (or a missing
    // transport mid-reconnect) surface as a toast instead of a silent no-op.

    public func playPause(zoneID: String) async {
        await runAction("Afspelen/pauzeren") { _ = try await $0.control(.playpause, zoneID: zoneID) }
    }

    public func next(zoneID: String) async {
        await runAction("Volgende track") { _ = try await $0.control(.next, zoneID: zoneID) }
    }

    public func previous(zoneID: String) async {
        await runAction("Vorige track") { _ = try await $0.control(.previous, zoneID: zoneID) }
    }

    public func setVolume(outputID: String, value: Int) async {
        await runAction("Volume") { _ = try await $0.changeVolume(outputID: outputID, how: "absolute", value: value) }
    }

    public func seek(zoneID: String, seconds: Double) async {
        await runAction("Spoelen") { _ = try await $0.seek(zoneID: zoneID, how: "absolute", seconds: seconds) }
    }

    public func adjustVolume(outputID: String, delta: Int) async {
        await runAction("Volume") { _ = try await $0.changeVolume(outputID: outputID, how: "relative", value: delta) }
    }

    public func toggleMute(outputID: String, muted: Bool) async {
        await runAction(muted ? "Dempen" : "Dempen opheffen") { _ = try await $0.mute(outputID: outputID, muted: muted) }
    }

    public func setShuffle(zoneID: String, enabled: Bool) async {
        await runAction("Shuffle") { _ = try await $0.setShuffle(zoneID: zoneID, enabled: enabled) }
    }

    public func setRepeat(zoneID: String, mode: String) async {
        let rMode = TransportService.RepeatMode(rawValue: mode) ?? .off
        await runAction("Herhalen") { _ = try await $0.setRepeat(zoneID: zoneID, mode: rMode) }
    }

    /// Play a list of tracks by their Roon item_keys using the browse API.
    /// First track plays immediately; subsequent tracks are queued.
    public func curateTracks(_ tracks: [TrackRecord], zoneID: String) async {
        guard let browse = browseService else {
            lastActionError = ActionError(message: "Afspelen mislukt — geen verbinding met Roon.")
            return
        }
        var isFirst = true
        var failed = 0
        for track in tracks {
            do {
                try await browse.playByBrowse(
                    itemKey: track.id, title: track.title, artist: track.artist,
                    zoneID: zoneID, action: isFirst ? "play_now" : "queue")
            } catch {
                failed += 1
            }
            isFirst = false
        }
        if failed > 0 {
            lastActionError = ActionError(
                message: failed == tracks.count
                    ? "Afspelen mislukt — geen van de \(tracks.count) tracks kon starten."
                    : "\(failed) van de \(tracks.count) tracks konden niet in de wachtrij.")
        }
    }

}
