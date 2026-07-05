import AudioAnalysis
import Foundation

/// Serialises listen-logging and scrobbling per zone, with a minimum-play
/// gate. Previously every now-playing change fired an unordered
/// `Task.detached` immediately: skip-spamming a zone scrobbled two-second
/// "plays", and concurrent tasks could submit out of order.
///
/// Rules (Last.fm guidelines): a track counts after half its length or
/// 4 minutes, whichever comes first, with a 30-second floor. The pending
/// commit is cancelled when the zone changes track (or disappears) before
/// the gate. Pausing mid-track does not stop the clock — acceptable v1
/// simplification; the gate still filters the skip-spam case.
actor ScrobbleCoordinator {

    struct Item: Sendable {
        var title: String
        var artist: String?
        var album: String?
        /// Track length in seconds, when Roon reports it.
        var length: Double?
        var zoneID: String
        var zoneName: String
    }

    private var pending: [String: Task<Void, Never>] = [:]
    /// Per-zone currently-playing item + the wall-clock it started, for skip
    /// detection: a track replaced well before its natural end was skipped.
    private var current: [String: (item: Item, startedAt: Double)] = [:]

    /// Below this many seconds of play, a track change is an early SKIP (implicit
    /// dislike) rather than a natural transition. Long enough to ignore a few
    /// seconds of preview/glitch, short enough that a genuine listen never counts.
    private static let skipThreshold: Double = 25
    /// Ignore sub-2s changes (channel-flipping / transient now-playing glitches).
    private static let skipFloor: Double = 2

    /// Called on every now-playing change (already title-deduped by the
    /// caller). Cancels the zone's pending commit and schedules a new one.
    func trackChanged(_ item: Item, database: DatabaseManager?) {
        pending[item.zoneID]?.cancel()

        // Scrobble timestamp = play START time, captured now (the commit
        // runs minutes later).
        let now = Date().timeIntervalSince1970
        let startedAt = Int(now)

        // Skip detection: the track this one REPLACES, if it played only briefly,
        // is an implicit dislike. Guarded so a short track ending naturally (its
        // length ≈ how long it played) isn't counted.
        if let prev = current[item.zoneID] {
            let played = now - prev.startedAt
            let prevLen = prev.item.length ?? 240
            if played >= Self.skipFloor, played < Self.skipThreshold, prevLen >= 30 {
                let mk = TrackIdentity.matchKey(artist: prev.item.artist, album: prev.item.album,
                                                title: prev.item.title)
                if !mk.isEmpty {
                    Task { try? await database?.logSkip(matchKey: mk) }
                }
            }
        }
        current[item.zoneID] = (item, now)

        // "Now playing" status is not a scrobble — update it right away.
        Task { await Self.updateNowPlaying(item) }

        let gate = min(max((item.length ?? 240) / 2, 30), 240)
        pending[item.zoneID] = Task {
            try? await Task.sleep(nanoseconds: UInt64(gate * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await Self.commit(item, startedAt: startedAt, database: database)
        }
    }

    func zoneRemoved(_ zoneID: String) {
        pending[zoneID]?.cancel()
        pending[zoneID] = nil
        // A stop/zone-disappear is NOT a skip — forget the current track so the
        // next play in this zone doesn't retroactively count it as skipped.
        current[zoneID] = nil
    }

    // MARK: - Submission

    private static func updateNowPlaying(_ item: Item) async {
        // Roon scrobbelt zelf al naar Last.fm; app-side scrobbelen staat default
        // uit om dubbele scrobbles / now-playing-conflicten te voorkomen.
        guard lastfmScrobbleEnabled(),
              let creds = lastfmCreds(), let artist = item.artist, !artist.isEmpty else { return }
        await LastfmClient.shared.updateNowPlaying(
            artist: artist, track: item.title, album: item.album, creds: creds)
    }

    /// The gated commit: local listening history + ListenBrainz + Last.fm.
    private static func commit(_ item: Item, startedAt: Int, database: DatabaseManager?) async {
        try? await database?.logListen(
            title: item.title, artist: item.artist, album: item.album,
            zoneID: item.zoneID, zoneName: item.zoneName)

        if let token = KeychainStore.load(key: "listenbrainz_token"), !token.isEmpty {
            await ListenBrainzClient.shared.submit(
                title: item.title, artist: item.artist, album: item.album,
                listenedAt: startedAt, token: token)
        }

        if lastfmScrobbleEnabled(), let creds = lastfmCreds(), let artist = item.artist, !artist.isEmpty {
            await LastfmClient.shared.scrobble(
                artist: artist, track: item.title, album: item.album,
                timestamp: startedAt, creds: creds)
        }
    }

    /// App-side Last.fm-scrobbelen. Default `false`: Roon's eigen Last.fm-
    /// integratie scrobbelt al, dus de app doet het niet om dubbele scrobbles
    /// te vermijden. Last.fm-data lezen (import/top-lijsten) werkt los hiervan.
    static func lastfmScrobbleEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: "lastfm_scrobble_enabled")
    }

    private static func lastfmCreds() -> LastfmClient.Credentials? {
        guard let apiKey = KeychainStore.load(key: "lastfm_api_key"), !apiKey.isEmpty,
              let secret = KeychainStore.load(key: "lastfm_api_secret"), !secret.isEmpty,
              let sk = KeychainStore.load(key: "lastfm_session_key"), !sk.isEmpty
        else { return nil }
        return LastfmClient.Credentials(apiKey: apiKey, apiSecret: secret, sessionKey: sk)
    }
}
