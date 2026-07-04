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

    /// Display name for the on-device output in the output picker.
    public static var localOutputName: String {
        #if os(macOS)
        "Deze Mac"
        #else
        "Dit apparaat"
        #endif
    }

    /// SF Symbol for the on-device output in the output picker.
    public static var localOutputIcon: String {
        #if os(macOS)
        "laptopcomputer"
        #else
        "iphone"
        #endif
    }

    /// The on-device playback engine — the UI binds to its observable state.
    public var localPlayback: LocalPlaybackController { .shared }

    /// Whether the user chose to listen on this device instead of a Roon zone.
    /// Persisted so it survives relaunch.
    public var localOutputSelected: Bool {
        get { UserDefaults.standard.bool(forKey: "local_output_selected") }
        set { UserDefaults.standard.set(newValue, forKey: "local_output_selected") }
    }

    /// Experimental: also stream Qobuz-in-library tracks to this device via
    /// Qobuz's unofficial API. Off by default (ToS-gray, needs the app_secret).
    public var qobuzLocalStreamEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "qobuz_local_stream_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "qobuz_local_stream_enabled") }
    }

    /// The Qobuz web-player `app_secret` used to sign streaming requests. Stored
    /// in the Keychain; the user pastes the current value (Qobuz rotates it).
    public var qobuzAppSecret: String? {
        get { KeychainStore.load(key: "qobuz_app_secret") }
        set {
            let v = (newValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { KeychainStore.delete(key: "qobuz_app_secret") }
            else { KeychainStore.save(key: "qobuz_app_secret", value: v) }
        }
    }

    /// Analyser base that serves `/audio` (and `/features`). Mirrors the feature
    /// sync's resolution: the configured analyzer URL, else the server host on
    /// the analyzer's default port.
    func localStreamBase() -> String {
        // Live connection first: featuresURL follows the host we're actually
        // connected over (LAN at home, ZeroTier on mobile data) — the stored
        // analyzer URL would pin /audio streaming to the LAN address.
        if isRemote, let base = remoteBaseURL { return featuresURL(serverBase: base) }
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
        let playableKeys = Set(part.playable.map { LocalPlayability.matchKey(for: $0) })

        // Optional experimental Qobuz fallback for the blocked (streaming-only)
        // tracks. Best-effort: any that don't resolve simply stay blocked.
        let qobuzURLs = await resolveQobuzStreams(for: part.blocked)

        // Loudness references for normalization (LMS-style, applied client-side).
        // Cheap lookups against the already-synced feature rows; empty maps when
        // nothing is measured — the engine then falls back to its assumed level.
        let allKeys = tracks.map { LocalPlayability.matchKey(for: $0) }
        let lufsByKey = await database?.loudnessByMatchKey(allKeys) ?? [:]
        let albumNames = Array(Set(tracks.compactMap { $0.album }))
        let albumLufs = await database?.albumMeanLoudness(albums: albumNames) ?? [:]

        // Build the queue in the ORIGINAL order, mixing local-file and Qobuz items.
        var items: [LocalPlaybackController.Track] = []
        var blockedTitles: [String] = []
        for rec in tracks {
            let key = LocalPlayability.matchKey(for: rec)
            let artist = rec.artist ?? "", album = rec.album ?? ""
            if playableKeys.contains(key) {
                items.append(.init(id: key, title: rec.title, artist: artist, album: album,
                                   imageKey: rec.imageKey, durationSec: nil,
                                   lufs: lufsByKey[key], albumLufs: albumLufs[album]))
            } else if let url = qobuzURLs[key] {
                items.append(.init(id: key, title: rec.title, artist: artist, album: album,
                                   imageKey: rec.imageKey, durationSec: nil, streamURLOverride: url,
                                   lufs: lufsByKey[key], albumLufs: albumLufs[album]))
            } else {
                blockedTitles.append(rec.title)
            }
        }
        let summary = LocalPlaybackSummary(
            requested: tracks.count, playable: items.count, blocked: blockedTitles.count,
            blockedExamples: Array(blockedTitles.prefix(3)))
        lastLocalPlaybackSummary = summary
        guard !items.isEmpty else {
            lastActionError = ActionError(
                message: "Geen van deze nummers is lokaal te spelen op deze iPhone (Qobuz/stream of niet op schijf).")
            return summary
        }
        localOutputSelected = true
        localPlayback.play(items, streamBase: base,
                           token: LibraryShareServer.configuredToken, startAt: startAt)
        return summary
    }

    /// Resolve Qobuz CDN URLs for blocked tracks when the experimental toggle is
    /// on and credentials + app_secret are present. Returns [matchKey: URL].
    private func resolveQobuzStreams(for blocked: [TrackRecord]) async -> [String: URL] {
        guard qobuzLocalStreamEnabled, !blocked.isEmpty,
              let secret = qobuzAppSecret, !secret.isEmpty,
              let email = KeychainStore.load(key: "qobuz_email"), !email.isEmpty,
              let pw = KeychainStore.load(key: "qobuz_password"), !pw.isEmpty else { return [:] }
        let reqs = blocked.map {
            (key: LocalPlayability.matchKey(for: $0), title: $0.title, artist: $0.artist, album: $0.album)
        }
        return await QobuzClient.shared.streamURLs(for: reqs, appSecret: secret, email: email, password: pw)
    }

    /// Map a library-track row to a `TrackRecord` for local playback.
    private func record(_ t: DatabaseManager.LibraryTrackRow) -> TrackRecord {
        TrackRecord(id: t.id, title: t.title, artist: t.artist, album: t.album,
                    year: t.year, isLive: t.isLive)
    }

    /// Fetch an album's tracks and play them on this device.
    @discardableResult
    public func playAlbumLocally(albumKey: String) async -> LocalPlaybackSummary? {
        let rows = await tracksForAlbum(albumKey)
        return await playLocally(rows.map(record))
    }

    /// Fetch all of an artist's tracks (across their albums) and play them on
    /// this device, in album order.
    @discardableResult
    public func playArtistLocally(name: String) async -> LocalPlaybackSummary? {
        let albums = await albumsByArtist(name)
        var recs: [TrackRecord] = []
        for album in albums {
            recs.append(contentsOf: (await tracksForAlbum(album.albumKey)).map(record))
        }
        return await playLocally(recs)
    }

    /// Make this device the active output. Future "play" actions route here (see
    /// `playToActiveOutput`) and the Now Playing screen shows the local player —
    /// even before anything is loaded. Selecting a Roon zone clears this again
    /// (`selectZone`).
    public func selectLocalOutput() {
        localOutputSelected = true
    }

    /// True when there's somewhere to play — a Roon zone or this device.
    public var hasActiveOutput: Bool { localOutputSelected || selectedZone != nil }

    /// Route a "play now" request to whichever output is active: on-device when
    /// selected, otherwise the selected Roon zone. Lets the primary play verbs
    /// (Speel alles / Speel nu) follow the chosen output instead of always
    /// targeting a zone.
    public func playToActiveOutput(_ tracks: [TrackRecord]) async {
        if localOutputSelected {
            await playLocally(tracks)
        } else if let zone = selectedZone {
            await curateTracks(tracks, zoneID: zone.id)
        }
    }

    /// Stop on-device playback and clear the "listen here" choice.
    public func stopLocalPlayback() {
        localPlayback.stop()
        localOutputSelected = false
    }

    /// Sleep-timer action: pause whatever is playing on this device — the local
    /// ("Deze iPhone") player if engaged, and the selected Roon zone if playing.
    public func pauseForSleep() async {
        if localPlayback.isPlaying { localPlayback.togglePlayPause() }
        if let zone = selectedZone, zone.state == .playing {
            await playPause(zoneID: zone.id)
        }
    }
}
