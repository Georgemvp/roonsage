import AudioAnalysis
import Foundation

/// "Phone as audio device": start on-device playback of library tracks, routed
/// through `LocalPlaybackController`. Tracks without an on-disk file (e.g.
/// Qobuz-only library entries) are dropped and reported via
/// `lastLocalPlaybackSummary` so the UI can show what was skipped.
@MainActor
extension RoonClient {
    /// Synthetic output id for "this device" in the zone/output picker.
    public static let localOutputID = "roonsage.local.device"

    /// The on-device playback engine — the UI binds to its observable state.
    public var localPlayback: LocalPlaybackController { .shared }

    /// Whether the user chose to listen on this device instead of a Roon zone.
    /// Persisted so it survives relaunch.
    public var localOutputSelected: Bool {
        get { UserDefaults.standard.bool(forKey: "local_output_selected") }
        set { UserDefaults.standard.set(newValue, forKey: "local_output_selected") }
    }

    /// Analyser base that serves `/audio` (and `/features`). Mirrors the feature
    /// sync's resolution: the configured analyzer URL, else the server host on
    /// the analyzer's default port.
    func localStreamBase() -> String {
        if !analyzerURL.isEmpty { return analyzerURL }
        if let base = remoteBaseURL { return featuresURL(serverBase: base) }
        return ""
    }

    /// Partition a track list into locally-playable vs. blocked, without
    /// starting playback — lets a view preview the filter before committing.
    public func localPlayabilityPartition(_ tracks: [TrackRecord]) async -> LocalPlayability.Partition {
        guard let db = database else { return .init(playable: [], blocked: tracks) }
        let keys = (try? await db.playableMatchKeys()) ?? []
        return LocalPlayability.partition(tracks, playableKeys: keys)
    }

    /// Start playing `tracks` on this device, dropping any that aren't locally
    /// playable. Records a `LocalPlaybackSummary` for the UI. Returns it (nil
    /// when there was nothing to resolve / no server).
    @discardableResult
    public func playLocally(_ tracks: [TrackRecord], startAt: Int = 0) async -> LocalPlaybackSummary? {
        guard !tracks.isEmpty else { return nil }
        let base = localStreamBase()
        guard !base.isEmpty else {
            lastActionError = ActionError(message: "Geen analyzer-server gevonden om lokaal af te spelen.")
            return nil
        }
        let part = await localPlayabilityPartition(tracks)
        let summary = LocalPlaybackSummary(
            requested: tracks.count,
            playable: part.playable.count,
            blocked: part.blocked.count,
            blockedExamples: Array(part.blocked.prefix(3).map(\.title)))
        lastLocalPlaybackSummary = summary
        guard !part.playable.isEmpty else {
            lastActionError = ActionError(
                message: "Geen van deze nummers staat lokaal op schijf — niets om op deze iPhone af te spelen.")
            return summary
        }
        let items = part.playable.map { rec in
            LocalPlaybackController.Track(
                id: LocalPlayability.matchKey(for: rec),
                title: rec.title,
                artist: rec.artist ?? "",
                album: rec.album ?? "",
                imageKey: rec.imageKey,
                durationSec: nil)
        }
        localOutputSelected = true
        localPlayback.play(items, streamBase: base,
                           token: LibraryShareServer.configuredToken, startAt: startAt)
        return summary
    }

    /// Stop on-device playback and clear the "listen here" choice.
    public func stopLocalPlayback() {
        localPlayback.stop()
        localOutputSelected = false
    }
}
