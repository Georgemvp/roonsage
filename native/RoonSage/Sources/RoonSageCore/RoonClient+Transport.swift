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
        if isRemote { var c = RemoteCommand("playPause"); c.zoneID = zoneID; await remote(c); return }
        await runAction("Afspelen/pauzeren") { _ = try await $0.control(.playpause, zoneID: zoneID) }
    }

    public func next(zoneID: String) async {
        if isRemote { var c = RemoteCommand("next"); c.zoneID = zoneID; await remote(c); return }
        // Skip re-steer: a skip on the active station's zone is a soft negative.
        // Capture the outgoing now-playing track before advancing. Remote skips
        // land here too — the server routes RemoteCommand("next") through next().
        noteRadioSkipIfActive(zoneID: zoneID)
        await runAction("Volgende track") { _ = try await $0.control(.next, zoneID: zoneID) }
    }

    /// Feed the current now-playing track into the active station's skip re-steer,
    /// when this zone IS the running station. No-op otherwise.
    private func noteRadioSkipIfActive(zoneID: String) {
        guard let state = radioState, state.zoneID == zoneID,
              let np = zoneMap[zoneID]?.nowPlaying else { return }
        recordRadioSkip(matchKey: TrackIdentity.matchKey(artist: np.artist, album: np.album, title: np.title))
    }

    public func previous(zoneID: String) async {
        if isRemote { var c = RemoteCommand("previous"); c.zoneID = zoneID; await remote(c); return }
        await runAction("Vorige track") { _ = try await $0.control(.previous, zoneID: zoneID) }
    }

    public func setVolume(outputID: String, value: Int) async {
        if isRemote { var c = RemoteCommand("setVolume"); c.outputID = outputID; c.value = value; await remote(c); return }
        await runAction("Volume") { _ = try await $0.changeVolume(outputID: outputID, how: "absolute", value: value) }
    }

    public func seek(zoneID: String, seconds: Double) async {
        if isRemote { var c = RemoteCommand("seek"); c.zoneID = zoneID; c.seconds = seconds; await remote(c); return }
        await runAction("Spoelen") { _ = try await $0.seek(zoneID: zoneID, how: "absolute", seconds: seconds) }
    }

    public func adjustVolume(outputID: String, delta: Int) async {
        if isRemote { var c = RemoteCommand("adjustVolume"); c.outputID = outputID; c.delta = delta; await remote(c); return }
        await runAction("Volume") { _ = try await $0.changeVolume(outputID: outputID, how: "relative", value: delta) }
    }

    public func toggleMute(outputID: String, muted: Bool) async {
        if isRemote { var c = RemoteCommand("toggleMute"); c.outputID = outputID; c.muted = muted; await remote(c); return }
        await runAction(muted ? "Dempen" : "Dempen opheffen") { _ = try await $0.mute(outputID: outputID, muted: muted) }
    }

    public func setShuffle(zoneID: String, enabled: Bool) async {
        if isRemote { var c = RemoteCommand("setShuffle"); c.zoneID = zoneID; c.enabled = enabled; await remote(c); return }
        await runAction("Shuffle") { _ = try await $0.setShuffle(zoneID: zoneID, enabled: enabled) }
    }

    public func setRepeat(zoneID: String, mode: String) async {
        if isRemote { var c = RemoteCommand("setRepeat"); c.zoneID = zoneID; c.mode = mode; await remote(c); return }
        let rMode = TransportService.RepeatMode(rawValue: mode) ?? .off
        await runAction("Herhalen") { _ = try await $0.setRepeat(zoneID: zoneID, mode: rMode) }
    }

    /// Play a list of tracks by their Roon item_keys using the browse API.
    /// First track plays immediately; subsequent tracks are queued.
    public func curateTracks(_ tracks: [TrackRecord], zoneID: String) async {
        if isRemote { var c = RemoteCommand("curate"); c.zoneID = zoneID; c.tracks = tracks; await remote(c); return }
        guard let browse = browseService else {
            lastActionError = ActionError(message: "Afspelen mislukt — geen verbinding met Roon.")
            return
        }
        let tracks = await resolveImportKeys(tracks)
        Log.info("curateTracks: \(tracks.count) tracks → zone \(zoneID)", category: .roon)
        var isFirst = true
        var failed = 0
        for track in tracks {
            do {
                try await browse.playByBrowse(
                    itemKey: track.id, title: track.title, artist: track.artist,
                    zoneID: zoneID, action: isFirst ? "play_now" : "queue")
                Log.debug("curate ok: '\(track.title)' (\(isFirst ? "play_now" : "queue"))", category: .roon)
            } catch {
                failed += 1
                Log.warning("curate FAILED: '\(track.title)' key=\(track.id.prefix(40)) — \(error)", category: .roon)
            }
            isFirst = false
        }
        Log.info("curateTracks done: \(tracks.count - failed)/\(tracks.count) ok", category: .roon)
        if failed > 0 {
            lastActionError = ActionError(
                message: failed == tracks.count
                    ? "Afspelen mislukt — geen van de \(tracks.count) tracks kon starten."
                    : "\(failed) van de \(tracks.count) tracks konden niet in de wachtrij.")
        }
    }

    /// Swap synthetic `import::` playback keys for the real Roon item_key this
    /// server owns, resolved by content `match_key`. A client that imported the
    /// library over the wire holds `import::artist::title` ids (the exporter's
    /// Roon keys are session-scoped and meaningless off-device); left as-is they
    /// force `playByBrowse` down a live Roon search that is slow and flaky under a
    /// degraded session. This server DOES hold the current key for any owned
    /// track, so resolving here makes discovery playback take the fast, reliable
    /// direct-browse path. Non-library keys (`qobuz_search::`, unresolved
    /// imports) pass through unchanged and still fall back to search.
    func resolveImportKeys(_ tracks: [TrackRecord]) async -> [TrackRecord] {
        guard let db = database else { return tracks }
        var out: [TrackRecord] = []
        out.reserveCapacity(tracks.count)
        for track in tracks {
            guard track.id.hasPrefix(DatabaseManager.importKeyPrefix) else { out.append(track); continue }
            if let realID = await db.libraryTrackID(matchKey: LocalPlayability.matchKey(for: track)) {
                var t = track; t.id = realID; out.append(t)
            } else {
                out.append(track)
            }
        }
        return out
    }

}
