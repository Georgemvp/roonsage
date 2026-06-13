import Foundation
import MediaPlayer
import RoonSageCore
import RoonSageUI

/// Mirrors the selected zone's now-playing onto `MPNowPlayingInfoCenter` and
/// routes Lock Screen / Control Center / AirPods / CarPlay transport commands
/// back to the Roon zone via `RoonClient`.
///
/// Note: RoonSage plays no local audio (the Core's zone does), so iOS may not
/// surface these controls while the app is suspended — without an active
/// audio session the system can hand "now playing" to another app. While the
/// app is foregrounded or recently active the controls work; full
/// always-available control needs a background-audio strategy later.
@MainActor
final class NowPlayingCenter {
    private weak var client: RoonClient?
    private var artworkKey: String?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    /// Wire the remote commands once. Safe to call once at app start.
    func configure(client: RoonClient) {
        self.client = client
        UIApplication.shared.beginReceivingRemoteControlEvents()

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.run { c, z in await c.playPause(zoneID: z) } ?? .noActionableNowPlayingItem }
        center.pauseCommand.addTarget { [weak self] _ in self?.run { c, z in await c.playPause(zoneID: z) } ?? .noActionableNowPlayingItem }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.run { c, z in await c.playPause(zoneID: z) } ?? .noActionableNowPlayingItem }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.run { c, z in await c.next(zoneID: z) } ?? .noActionableNowPlayingItem }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.run { c, z in await c.previous(zoneID: z) } ?? .noActionableNowPlayingItem }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let pos = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            return self.run { c, z in await c.seek(zoneID: z, seconds: pos) }
        }
    }

    private func run(_ op: @escaping (RoonClient, String) async -> Void) -> MPRemoteCommandHandlerStatus {
        guard let client, let zoneID = client.selectedZone?.id else { return .noActionableNowPlayingItem }
        Task { await op(client, zoneID) }
        return .success
    }

    /// Reconcile the system now-playing info with the zone's current state.
    /// Call on track / state / zone change (same cadence as the Live Activity).
    func sync(zone: Zone?) {
        let info = MPNowPlayingInfoCenter.default()
        guard let zone, let np = zone.nowPlaying,
              zone.state == .playing || zone.state == .paused else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }

        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: np.title,
            MPNowPlayingInfoPropertyPlaybackRate: zone.state == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if let artist = np.artist { dict[MPMediaItemPropertyArtist] = artist }
        if let album = np.album { dict[MPMediaItemPropertyAlbumTitle] = album }
        if let length = np.length, length > 0 {
            dict[MPMediaItemPropertyPlaybackDuration] = Double(length)
        }
        if let pos = zone.seekPosition {
            dict[MPNowPlayingInfoPropertyElapsedPlaybackTime] = pos
        }
        if let artwork, artworkKey == np.imageKey {
            dict[MPMediaItemPropertyArtwork] = artwork
        }
        info.nowPlayingInfo = dict
        info.playbackState = zone.state == .playing ? .playing : .paused

        loadArtworkIfNeeded(for: np.imageKey)
    }

    /// Fetch album art through the shared image cache and patch it into the
    /// now-playing dict once decoded (the Roon image server is only reachable
    /// while the app's connection is open, so cache aggressively).
    private func loadArtworkIfNeeded(for key: String?) {
        guard let key, key != artworkKey else { return }
        artworkKey = key
        artwork = nil
        guard let url = client?.imageURL(forKey: key, size: 600) else { return }
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let image = await ImageCache.shared.image(for: url),
                  let self, !Task.isCancelled, self.artworkKey == key else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.artwork = art
            // Patch into the existing info without rebuilding (avoids racing
            // a concurrent sync()).
            if var dict = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                dict[MPMediaItemPropertyArtwork] = art
                MPNowPlayingInfoCenter.default().nowPlayingInfo = dict
            }
        }
    }
}
