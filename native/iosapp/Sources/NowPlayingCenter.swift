import Foundation
import MediaPlayer
import RoonSageCore
import RoonSageUI

/// Mirrors now-playing onto `MPNowPlayingInfoCenter` and routes Lock Screen /
/// Control Center / AirPods / CarPlay transport commands.
///
/// Two sources, one writer: when on-device (local) playback is engaged it owns
/// the surface — there's a real `AVAudioSession`, so the controls work
/// continuously even while the app is suspended. Otherwise it mirrors the
/// selected Roon zone (which plays no local audio, so iOS may drop the controls
/// once the app is suspended).
@MainActor
final class NowPlayingCenter {
    private weak var client: RoonClient?
    private var artworkKey: String?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var local: LocalPlaybackController { .shared }

    /// Wire the remote commands once. Safe to call once at app start.
    func configure(client: RoonClient) {
        self.client = client
        UIApplication.shared.beginReceivingRemoteControlEvents()

        // Keep the lock screen in step with the local engine (track / play /
        // pause / ~2 Hz position) without the app having to poll it.
        local.onStateChange = { [weak self] in self?.sync(zone: self?.client?.selectedZone) }

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.handlePlayPause(resume: true) ?? .noActionableNowPlayingItem }
        center.pauseCommand.addTarget { [weak self] _ in self?.handlePlayPause(resume: false) ?? .noActionableNowPlayingItem }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.handlePlayPause(resume: nil) ?? .noActionableNowPlayingItem }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.handleSkip(forward: true) ?? .noActionableNowPlayingItem }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.handleSkip(forward: false) ?? .noActionableNowPlayingItem }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let pos = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            if self.local.isEngaged { self.local.seek(toSeconds: pos); return .success }
            return self.run { c, z in await c.seek(zoneID: z, seconds: pos) }
        }
    }

    // MARK: - Remote command routing (local engine vs. Roon zone)

    private func handlePlayPause(resume: Bool?) -> MPRemoteCommandHandlerStatus {
        if local.isEngaged {
            switch resume {
            case .some(true): if !local.isPlaying { local.togglePlayPause() }
            case .some(false): if local.isPlaying { local.togglePlayPause() }
            case .none: local.togglePlayPause()
            }
            return .success
        }
        return run { c, z in await c.playPause(zoneID: z) }
    }

    private func handleSkip(forward: Bool) -> MPRemoteCommandHandlerStatus {
        if local.isEngaged { forward ? local.next() : local.previous(); return .success }
        return run { c, z in forward ? await c.next(zoneID: z) : await c.previous(zoneID: z) }
    }

    private func run(_ op: @escaping (RoonClient, String) async -> Void) -> MPRemoteCommandHandlerStatus {
        guard let client, let zoneID = client.selectedZone?.id else { return .noActionableNowPlayingItem }
        Task { await op(client, zoneID) }
        return .success
    }

    /// Reconcile the system now-playing info. Local playback wins when engaged;
    /// otherwise mirror the zone. Call on track / state / zone change.
    func sync(zone: Zone?) {
        if local.isEngaged { syncLocal(); return }
        let info = MPNowPlayingInfoCenter.default()
        // Only surface the zone on the lock screen while actually playing — a
        // paused/stopped Roon zone clears it (matches the Live Activity).
        guard let zone, let np = zone.nowPlaying, zone.state == .playing else {
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

    /// Now-playing info for the on-device engine. Position rides at ~2 Hz so the
    /// lock-screen scrubber tracks local playback accurately.
    private func syncLocal() {
        let info = MPNowPlayingInfoCenter.default()
        guard let t = local.current else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPNowPlayingInfoPropertyPlaybackRate: local.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if !t.artist.isEmpty { dict[MPMediaItemPropertyArtist] = t.artist }
        if !t.album.isEmpty { dict[MPMediaItemPropertyAlbumTitle] = t.album }
        let dur = local.durationSec
        if dur > 0 { dict[MPMediaItemPropertyPlaybackDuration] = dur }
        dict[MPNowPlayingInfoPropertyElapsedPlaybackTime] = local.positionSec
        if let artwork, artworkKey == t.imageKey {
            dict[MPMediaItemPropertyArtwork] = artwork
        }
        info.nowPlayingInfo = dict
        info.playbackState = local.isPlaying ? .playing : .paused

        loadArtworkIfNeeded(for: t.imageKey)
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
