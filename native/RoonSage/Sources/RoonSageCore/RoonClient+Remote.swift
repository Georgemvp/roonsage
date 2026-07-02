import Foundation
import Observation

/// How a RoonClient talks to Roon.
public enum RoonControlMode: Sendable {
    /// Direct Roon WebSocket — the always-on server build.
    case direct
    /// Via the RoonSage server over HTTP — the Mac/iOS client apps. No Roon
    /// extension is registered on this device; playback is proxied.
    case server
}

// MARK: - Wire DTOs (server ⇄ client, over /playback and /command on port 5767)

/// Live playback state the server hands to client apps.
public struct PlaybackSnapshot: Codable, Sendable {
    public var zones: [Zone]
    public var queueItems: [RoonClient.QueueItem]
    public var roonConnected: Bool
    public var coreName: String?
    public var coreHost: String?
    public var corePort: Int
    public var trackCount: Int
    /// Opaque "library changed" marker (track count + last-sync time). Clients
    /// re-pull the library when it differs from what they last imported.
    public var libraryRevision: String?
}

/// A control command a client sends to the server. Flat (not an enum with
/// associated values) so it round-trips as plain JSON. `action` selects the
/// RoonClient method; the rest are optional params.
public struct RemoteCommand: Codable, Sendable {
    public var action: String
    public var zoneID: String?
    public var outputID: String?
    public var value: Int?
    public var delta: Int?
    public var muted: Bool?
    public var seconds: Double?
    public var enabled: Bool?
    public var mode: String?
    public var fromZoneID: String?
    public var toZoneID: String?
    public var queueItemID: Int?
    public var next: Bool?
    public var tracks: [TrackRecord]?

    public init(_ action: String) { self.action = action }
}

@MainActor
extension RoonClient {

    // MARK: - Server side (the analyzer/server build, .direct mode)

    /// Snapshot of the server's live Roon state for a client poll. When `zoneID`
    /// is given, (idempotently) subscribes to that zone's queue so the client
    /// sees the right queue.
    public func playbackSnapshot(forZone zoneID: String?) -> PlaybackSnapshot {
        if let zoneID, !zoneID.isEmpty, queueZoneID != zoneID {
            startQueue(zoneID: zoneID)
        }
        var coreName: String?
        if case let .connected(name) = connectionState { coreName = name }
        let lastSync = (try? database?.syncStateValue(forKey: "last_sync")) ?? nil
        // featuresRevision is a CACHED in-memory string (set by the analyzer app
        // when it starts serving) — NOT a per-poll DB query, which previously
        // stalled this MainActor path. It changes when analyses change, so
        // remotes auto-re-pull features/embeddings even if the Roon library
        // itself didn't change.
        // Overlay the live per-second seek (kept out of the observable `zones`)
        // so remote clients see an accurate, advancing position instead of the
        // last structural value frozen until the next track change.
        let freshZones = zones.map { zone -> Zone in
            guard let live = liveSeek[zone.id], zone.nowPlaying != nil else { return zone }
            var z = zone
            z.seekPosition = live
            return z
        }
        return PlaybackSnapshot(
            zones: freshZones,
            queueItems: queueItems,
            roonConnected: connectionState.isConnected,
            coreName: coreName,
            coreHost: coreHost,
            corePort: Int(corePort),
            trackCount: trackCount,
            libraryRevision: "\(trackCount)|\(lastSync ?? "")|\(featuresRevision)"
        )
    }

    /// Encoded `/playback` body for the share server (keeps RoonClient.shared
    /// access on the MainActor).
    public func snapshotData(forZone zone: String?) -> Data {
        (try? JSONEncoder().encode(playbackSnapshot(forZone: zone))) ?? Data("{}".utf8)
    }

    /// Decode + run a `/command` body. Returns false on a malformed payload.
    @discardableResult
    public func runRemoteCommandData(_ data: Data) async -> Bool {
        guard let cmd = try? JSONDecoder().decode(RemoteCommand.self, from: data) else { return false }
        await applyRemoteCommand(cmd)
        return true
    }

    /// Execute a proxied command on the real Roon connection (server side).
    public func applyRemoteCommand(_ c: RemoteCommand) async {
        Log.info("remote-command '\(c.action)' zone=\(c.zoneID ?? "-") tracks=\(c.tracks?.count ?? 0) (mode=\(controlMode), transport=\(transportService != nil), browse=\(browseService != nil))", category: .network)
        switch c.action {
        case "playPause":     if let z = c.zoneID { await playPause(zoneID: z) }
        case "next":          if let z = c.zoneID { await next(zoneID: z) }
        case "previous":      if let z = c.zoneID { await previous(zoneID: z) }
        case "seek":          if let z = c.zoneID, let s = c.seconds { await seek(zoneID: z, seconds: s) }
        case "setVolume":     if let o = c.outputID, let v = c.value { await setVolume(outputID: o, value: v) }
        case "adjustVolume":  if let o = c.outputID, let d = c.delta { await adjustVolume(outputID: o, delta: d) }
        case "toggleMute":    if let o = c.outputID, let m = c.muted { await toggleMute(outputID: o, muted: m) }
        case "setShuffle":    if let z = c.zoneID, let e = c.enabled { await setShuffle(zoneID: z, enabled: e) }
        case "setRepeat":     if let z = c.zoneID, let m = c.mode { await setRepeat(zoneID: z, mode: m) }
        case "transferZone":  if let f = c.fromZoneID, let t = c.toZoneID { await transferZone(fromZoneID: f, toZoneID: t) }
        case "playFromHere":  if let z = c.zoneID, let q = c.queueItemID { await playFromHere(zoneID: z, queueItemID: q) }
        // Loading a multi-track queue via Roon Browse takes far longer than the
        // client's command timeout — ack the HTTP request immediately and load
        // in the background; the client sees the result on its next /playback
        // poll. (Per-track failures stay server-side, as they did before.)
        case "curate":        if let z = c.zoneID, let t = c.tracks { Task { await self.curateTracks(t, zoneID: z) } }
        case "queue":         if let z = c.zoneID, let t = c.tracks { Task { await self.queueTracks(t, next: c.next ?? false, zoneID: z) } }
        default: break
        }
    }

    // MARK: - Client side (the Mac/iOS apps, .server mode)

    /// Switch this process to server (proxy) mode. Call once at launch before
    /// connecting. The client never registers a Roon extension.
    public static func useServerMode() {
        // Set the DB filename BEFORE the `shared` access below (which triggers
        // its lazy init and opens the database) so the client uses its own file
        // and never shares the server's library.db on the same machine.
        databaseFileOverride = "client-library.db"
        shared.controlMode = .server
        // A thin client must not run (or advertise) a share server: the macOS
        // autostart happens during init while the mode still looks `.direct`, so
        // stop it now that we know this is a client. Otherwise the client would
        // find its own Bonjour advertisement and "connect" to localhost.
        shared.setLibrarySharing(enabled: false)
    }

    /// "Connect" in server mode: find the RoonSage server and start polling its
    /// playback state. Safe to call repeatedly.
    func startServerMode() async {
        guard isRemote else { return }
        // A client must never target loopback — that's its own (legacy) share
        // server, not the real one. Drop a remembered localhost so we re-discover
        // the actual server; also self-heals a bad value persisted by an earlier
        // build that discovered itself.
        if let base = remoteBaseURL, let h = URL(string: base)?.host, Self.isLoopback(h) {
            remoteBaseURL = nil
        }
        // Re-discover when we have no server yet OR the remembered one has gone
        // quiet — a server that moved to a new DHCP address is found again via
        // Bonjour without the user re-typing anything. (Split out so the `await`
        // isn't inside a `||` autoclosure, which the compiler rejects.)
        let needsDiscovery: Bool
        if let base = remoteBaseURL {
            needsDiscovery = !(await shareServerReachable(base))
        } else {
            needsDiscovery = true
        }
        if needsDiscovery {
            connectionState = .discovering
            if let found = await discoverShareServer() {
                remoteBaseURL = found
            } else if remoteBaseURL == nil,
                      let saved = UserDefaults.standard.string(forKey: "library_import_url"),
                      let h = URL(string: saved)?.host, !Self.isLoopback(h) {
                remoteBaseURL = saved
            }
            // Remember the live address so the connect screen and next launch
            // reconnect straight to it (never a loopback address).
            if let base = remoteBaseURL, let host = URL(string: base)?.host, !Self.isLoopback(host) {
                persistHost(host, port: LibraryShareServer.defaultPort)
                UserDefaults.standard.set(base, forKey: "library_import_url")
            }
        }
        guard remoteBaseURL != nil else {
            connectionState = .failed("Geen RoonSage-server gevonden op het netwerk.")
            return
        }
        startRemotePolling()
        await pollPlaybackOnce()
    }

    /// Quick liveness probe of a share-server base URL (`/health` → 200). Used to
    /// decide whether the remembered server is still there before trusting it.
    private func shareServerReachable(_ base: String) async -> Bool {
        guard let url = URL(string: "\(base)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return true
    }

    private func startRemotePolling() {
        guard remotePollTask == nil else { return }
        remotePollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollPlaybackOnce()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stopServerMode() {
        remotePollTask?.cancel()
        remotePollTask = nil
    }

    /// Attach this device's token + friendly name so the server accepts the
    /// request (master token, or an approved device token). On a fresh client
    /// `ensureDeviceToken()` mints a random token so it shows up as "pending" on
    /// the server for one-tap approval — no manual token entry needed.
    func authorizeShareRequest(_ req: inout URLRequest) {
        // On the server-of-record `ensureDeviceToken()` returns the master token
        // (already set) and the request is loopback/token-exempt anyway; on a
        // client it returns the paired or freshly-minted device token.
        req.setValue(LibraryShareServer.ensureDeviceToken(), forHTTPHeaderField: LibraryShareServer.tokenHeader)
        req.setValue(LibraryShareServer.thisDeviceName, forHTTPHeaderField: LibraryShareServer.deviceHeader)
    }

    /// Fetch /playback once and map it onto the observable state the UI binds to.
    func pollPlaybackOnce() async {
        guard isRemote, let base = remoteBaseURL else { return }
        var comps = URLComponents(string: "\(base)/playback")
        if let z = selectedZoneID { comps?.queryItems = [URLQueryItem(name: "zone", value: z)] }
        guard let url = comps?.url else { return }
        var req = URLRequest(url: url)
        // Tolerant: a heavy generate (Ollama on the server) or a long curate
        // queue-load can stall /playback well past a few seconds.
        req.timeoutInterval = 12
        authorizeShareRequest(&req)
        let serverHost = URL(string: base)?.host
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let snap = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data) else {
            // Transient blip — keep last-known zones and only fall back to the
            // connect screen after several misses in a row.
            remotePollFailures += 1
            if remotePollFailures >= 5 { connectionState = .disconnected }
            return
        }

        zones = snap.zones
        zoneMap = Dictionary(uniqueKeysWithValues: snap.zones.map { ($0.id, $0) })
        queueItems = snap.queueItems
        // The server reports the Core host as it sees it; when the Core runs on
        // the server itself that's loopback, useless to a remote client. Use the
        // server's address so album art (Core /api/image) loads.
        if let host = snap.coreHost {
            coreHost = (Self.isLoopback(host) ? serverHost : host) ?? host
        }
        corePort = UInt16(snap.corePort)
        trackCount = snap.trackCount

        if snap.roonConnected {
            remotePollFailures = 0
            connectionState = .connected(coreName: snap.coreName ?? "RoonSage Server")
        } else {
            // Server reachable but its Roon link is momentarily down — tolerate a
            // few before showing "connecting" so the UI doesn't flicker.
            remotePollFailures += 1
            if remotePollFailures >= 5 {
                connectionState = .connecting(host: serverHost ?? "server")
            }
        }

        // Auto-refresh: pull the library once in the background when the server's
        // copy changed, when we've never imported here (stored revision nil), or
        // after a client update (app version changed — picks up import-format
        // fixes like genres/features without a manual sync). Keyed so it runs
        // once per change, not per poll.
        let storedRev = UserDefaults.standard.string(forKey: "imported_library_revision")
        let storedVer = UserDefaults.standard.string(forKey: "imported_app_version")
        if let rev = snap.libraryRevision,
           (rev != storedRev || Self.appVersion != storedVer),
           !isSyncing, !isImportingFromServer {
            isImportingFromServer = true
            Task { [weak self] in await self?.refreshLibraryFromServer(base: base, revision: rev) }
        }
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Features endpoint: the configured analyzer URL, or — when the server
    /// didn't report one (it IS the analyzer and never set `analyzer_url`) — the
    /// server's own host on the analyzer's default port (5766). Persists the
    /// derived value so later syncs have it.
    func featuresURL(serverBase: String) -> String {
        let a = analyzerURL
        if !a.isEmpty { return a }
        if let host = URL(string: serverBase)?.host {
            let derived = "http://\(host):5766"
            analyzerURL = derived
            return derived
        }
        return a
    }

    /// Background library (+features) re-import triggered by a revision change.
    func refreshLibraryFromServer(base: String, revision: String) async {
        defer { isImportingFromServer = false }
        // Refresh settings first so the analyzer URL (and Roon host) stay correct
        // — the server now advertises its analyzer endpoint, so features pull
        // from the right port without guessing.
        _ = await importSettings(fromMac: base)
        guard await importLibrary(fromMac: base) != nil else { return }
        let aURL = featuresURL(serverBase: base)
        if !aURL.isEmpty { _ = await syncAudioFeatures(from: aURL) }
        UserDefaults.standard.set(revision, forKey: "imported_library_revision")
        UserDefaults.standard.set(Self.appVersion, forKey: "imported_app_version")
    }

    /// One-shot fetch of the server's current library revision (used to record a
    /// baseline after a manual sync so auto-refresh doesn't re-import).
    func fetchLibraryRevision(base: String) async -> String? {
        guard let url = URL(string: "\(base)/playback") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 5
        authorizeShareRequest(&req)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let snap = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data) else { return nil }
        return snap.libraryRevision
    }

    /// Send a proxied command to the server, then immediately re-poll so the UI
    /// reflects the result without waiting for the next tick.
    func remote(_ command: RemoteCommand) async {
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/command") else {
            lastActionError = ActionError(message: "Geen verbinding met de RoonSage-server.")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(command)
        authorizeShareRequest(&req)
        // Queue-loading commands can take far longer server-side than the rest
        // (an old server that still blocks the response would otherwise time out
        // mid-load); a truly-down server still fails fast via connection refusal.
        req.timeoutInterval = (command.action == "curate" || command.action == "queue") ? 180 : 8
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            await pollPlaybackOnce()
        } else {
            lastActionError = ActionError(message: "Commando mislukt — is de RoonSage-server bereikbaar?")
        }
    }
}
