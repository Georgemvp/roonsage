import Foundation
import Network
#if os(iOS)
import UIKit
#endif

/// Minimal HTTP server the client apps talk to. Exposes the synced library (so
/// the iPhone can import it instead of an hours-long Browse walk), the synced
/// settings, and — for the playback proxy — live playback state plus a command
/// endpoint so client apps control Roon through this server (only this process
/// registers a Roon extension).
///   GET  /library  → exportLibraryJSON()
///   GET  /history  → ListenSnapshot (taste-profile totals/top-artists/recent)
///   GET  /taste-analysis → TasteAnalysis (time/genre/decade + like/dislike summary)
///   GET  /settings → SyncableSettings
///   GET  /playback?zone=… → PlaybackSnapshot (live zones/now-playing/queue)
///   POST /command  → RemoteCommand (play/pause/volume/curate/…)
///   POST /track-feedback → TrackFeedback (like/dislike/clear a track)
///   GET  /feedback → [FeedbackEntry] (all like/dislike verdicts)
///   GET  /playlists → [PlaylistSummary] (all saved playlists)
///   POST /playlists → SavePlaylistRequest → {"id": n} (save a new playlist)
///   DELETE /playlists?id=n → delete a saved playlist
///   GET  /playlist-tracks?id=n → [TrackRecord] (stored tracks of a playlist)
///   GET  /artist-radios → [SonicRadioPlaylist] (last synced AI radios → Qobuz)
///   GET  /discover-weekly → DiscoverWeeklyPlaylist? (library-first weekly, or null)
///   POST /discover-weekly/refresh → rebuild this week now → DiscoverWeeklyPlaylist?
///   GET  /discovery/recommendations?kind=&limit= → [RecommendationItemDTO]
///   POST /discovery/accept | /discovery/play | /discovery/reject → DiscoveryActionRequest
///   POST /discovery/run    → kick a pipeline pass ({"ok":true})
///   GET  /discovery/run-status → DiscoveryRunStatus
///   GET  /health   → {"tracks": n}
public final class LibraryShareServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 5767   // 5766 is the analyzer

    // MARK: - Access token
    //
    // The server exposes the full library AND the synced settings — which carry
    // secrets (API keys, Last.fm session, Qobuz password). Binding on all
    // interfaces with no auth would hand those to anyone on the network. Every
    // endpoint but /health requires a shared secret, sent in `tokenHeader` (kept
    // out of the URL so it never lands in access logs). Same-machine (loopback)
    // callers are exempt; see `route`.

    /// Header a client sends its shared secret in.
    public static let tokenHeader = "X-RoonSage-Token"
    private static let tokenKey = "share_token"
    private static var cachedToken: String?

    /// The server's shared secret — generated once and persisted in the Keychain.
    /// Warmed in `start()` so request handling is a cache hit.
    public static func currentToken() -> String {
        if let c = cachedToken { return c }
        if let t = KeychainStore.load(key: tokenKey), !t.isEmpty { cachedToken = t; return t }
        var bytes = [UInt8](repeating: 0, count: 24)
        for i in bytes.indices { bytes[i] = .random(in: .min ... .max) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        KeychainStore.save(key: tokenKey, value: token)
        cachedToken = token
        return token
    }

    /// Token configured on this device — the server's generated one, or (on a
    /// client) the value the user pasted from the server. nil if unset.
    public static var configuredToken: String? { KeychainStore.load(key: tokenKey) }

    /// Set/clear the token on this device (client pairing UI).
    public static func setConfiguredToken(_ value: String) {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { KeychainStore.delete(key: tokenKey); cachedToken = nil }
        else { KeychainStore.save(key: tokenKey, value: t); cachedToken = t }
    }

    /// When false (default) unauthenticated requests are still served but logged
    /// — a grace window so existing clients keep working until they're paired.
    /// Flip to true to hard-reject them. A *wrong* token is always rejected.
    public static var enforceToken: Bool {
        get { UserDefaults.standard.bool(forKey: "share_token_enforce") }
        set { UserDefaults.standard.set(newValue, forKey: "share_token_enforce") }
    }

    // MARK: - Device approval (zero-config pairing)
    //
    // Instead of copy-pasting the master token onto every client, each client
    // mints its OWN random token (see `ensureDeviceToken`) and sends it plus a
    // friendly name in `deviceHeader`. An unknown token isn't a dead-end 401 any
    // more: the server files it in a pending queue that the analyzer app shows,
    // where the user taps "Accepteer" to move it into the approved set. The
    // master token still validates (existing paired clients keep working).

    /// Header a client sends its human-readable device name in.
    public static let deviceHeader = "X-RoonSage-Device"

    /// A client token the user has approved on the server.
    public struct ApprovedDevice: Codable, Sendable, Identifiable {
        public var id: String { token }
        public let token: String
        public var name: String
        public var approvedAt: Date
    }

    /// A client that has knocked with an unknown token and is awaiting approval.
    public struct PendingDevice: Codable, Sendable, Identifiable {
        public var id: String { token }
        public let token: String
        public var name: String
        public var ip: String
        public var firstSeen: Date
        public var lastSeen: Date
    }

    private static let deviceLock = NSLock()
    private static var _pending: [String: PendingDevice] = [:]
    private static var _approvedCache: [String: ApprovedDevice]?
    private static let approvedKey = "approved_devices"

    /// Caller must hold `deviceLock`.
    private static func loadApprovedLocked() -> [String: ApprovedDevice] {
        if let c = _approvedCache { return c }
        let arr = UserDefaults.standard.data(forKey: approvedKey)
            .flatMap { try? JSONDecoder().decode([ApprovedDevice].self, from: $0) } ?? []
        let map = Dictionary(arr.map { ($0.token, $0) }, uniquingKeysWith: { a, _ in a })
        _approvedCache = map
        return map
    }

    /// Caller must hold `deviceLock`.
    private static func persistApprovedLocked(_ map: [String: ApprovedDevice]) {
        _approvedCache = map
        if let data = try? JSONEncoder().encode(Array(map.values)) {
            UserDefaults.standard.set(data, forKey: approvedKey)
        }
    }

    /// True when `token` has been approved on this server.
    public static func isApprovedDevice(_ token: String) -> Bool {
        deviceLock.lock(); defer { deviceLock.unlock() }
        return loadApprovedLocked()[token] != nil
    }

    /// File (or refresh) an unknown-token client in the pending queue.
    static func recordPending(token: String, name: String, ip: String) {
        deviceLock.lock(); defer { deviceLock.unlock() }
        if loadApprovedLocked()[token] != nil { return }
        let now = Date()
        let display = name.isEmpty ? "Onbekend apparaat" : name
        if var p = _pending[token] {
            p.lastSeen = now
            if !name.isEmpty { p.name = name }
            if !ip.isEmpty { p.ip = ip }
            _pending[token] = p
        } else {
            _pending[token] = PendingDevice(token: token, name: display, ip: ip,
                                            firstSeen: now, lastSeen: now)
        }
    }

    /// Clients awaiting approval, oldest first.
    public static func pendingDevices() -> [PendingDevice] {
        deviceLock.lock(); defer { deviceLock.unlock() }
        return _pending.values.sorted { $0.firstSeen < $1.firstSeen }
    }

    /// Approved clients, oldest first.
    public static func approvedDevices() -> [ApprovedDevice] {
        deviceLock.lock(); defer { deviceLock.unlock() }
        return loadApprovedLocked().values.sorted { $0.approvedAt < $1.approvedAt }
    }

    /// Move a pending device into the approved set. Its next poll (~1.5s) succeeds.
    @discardableResult
    public static func approveDevice(token: String) -> Bool {
        deviceLock.lock(); defer { deviceLock.unlock() }
        guard let p = _pending[token] else { return false }
        var map = loadApprovedLocked()
        map[token] = ApprovedDevice(token: token, name: p.name, approvedAt: Date())
        persistApprovedLocked(map)
        _pending[token] = nil
        return true
    }

    /// Drop a device from the pending queue without approving it.
    public static func rejectDevice(token: String) {
        deviceLock.lock(); defer { deviceLock.unlock() }
        _pending[token] = nil
    }

    /// Revoke a previously approved device (it drops back to 401 on its next poll).
    public static func revokeDevice(token: String) {
        deviceLock.lock(); defer { deviceLock.unlock() }
        var map = loadApprovedLocked()
        map[token] = nil
        persistApprovedLocked(map)
    }

    /// This device's token for talking to a server: the configured one (master on
    /// the server, or a previously-set value on a client), or a freshly minted
    /// random client token persisted for next time. Lets clients pair with zero
    /// manual token entry — they just show up as "pending" on the server.
    public static func ensureDeviceToken() -> String {
        if let t = configuredToken, !t.isEmpty { return t }
        var bytes = [UInt8](repeating: 0, count: 24)
        for i in bytes.indices { bytes[i] = .random(in: .min ... .max) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        setConfiguredToken(token)
        return token
    }

    /// Friendly name this device advertises to the server for the approval list.
    public static var thisDeviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }

    private let port: UInt16
    private let database: DatabaseManager
    private var listener: NWListener?

    // /library is rebuilt (tens of MB for a large library) on each request, and
    // clients re-pull it whenever the /playback libraryRevision shifts (its
    // featuresRevision part changes during analysis) — though library CONTENT only
    // changes on a sync. Cache it, keyed on `last_sync`, so those re-pulls don't
    // rebuild. @unchecked Sendable → guard with a lock.
    private let libCacheLock = NSLock()
    private var libraryCache: (sig: String, data: Data)?

    public init(port: UInt16 = LibraryShareServer.defaultPort, database: DatabaseManager) {
        self.port = port
        self.database = database
    }

    public func start() throws {
        _ = Self.currentToken()   // warm the token cache before any request
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: .global())
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        let loopback = Self.endpointIsLoopback(conn.endpoint)
        let peerIP = Self.endpointHost(conn.endpoint)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.receive(conn, accumulated: Data(), loopback: loopback, peerIP: peerIP)
            case .failed, .cancelled: conn.cancel()
            default: break
            }
        }
        conn.start(queue: .global())
    }

    /// Accumulate until the full request (headers + any POST body) has arrived,
    /// then route. POST bodies don't always land in the first read.
    private func receive(_ conn: NWConnection, accumulated: Data, loopback: Bool, peerIP: String) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else { conn.cancel(); return }
            var buf = accumulated
            if let data { buf.append(data) }
            guard let headerEnd = Self.rangeOfHeaderEnd(buf) else {
                if isComplete { conn.cancel() } else { self.receive(conn, accumulated: buf, loopback: loopback, peerIP: peerIP) }
                return
            }
            let headerData = buf.subdata(in: buf.startIndex..<headerEnd.lowerBound)
            let header = String(data: headerData, encoding: .utf8) ?? ""
            let bodyStart = headerEnd.upperBound
            let contentLength = Self.contentLength(header)
            let bodyReceived = buf.count - (bodyStart - buf.startIndex)
            if bodyReceived < contentLength, !isComplete {
                self.receive(conn, accumulated: buf, loopback: loopback, peerIP: peerIP)
                return
            }
            // `contentLength` is clamped to [0, 32 MB] (see `contentLength`), so
            // this range can never invert — a negative/overflowing header value
            // used to trap here and crash the always-on extension process.
            let bodyEnd = min(bodyStart + contentLength, buf.endIndex)
            let body = buf.subdata(in: min(bodyStart, bodyEnd)..<bodyEnd)
            Task {
                let (status, respBody, ctype) = await self.route(header: header, body: body, loopback: loopback, peerIP: peerIP)
                self.send(conn, status: status, body: respBody, ctype: ctype)
            }
        }
    }

    private func send(_ conn: NWConnection, status: String, body: Data, ctype: String) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(ctype)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
        })
    }

    private func route(header: String, body: Data, loopback: Bool, peerIP: String = "") async -> (String, Data, String) {
        let requestLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ").map(String.init)
        let method = parts.first ?? "GET"
        let target = parts.count > 1 ? parts[1] : "/"
        let path = target.split(separator: "?").first.map(String.init) ?? target

        // Auth: everything but /health needs a valid token, unless the peer is
        // loopback (same machine — already OS-trusted) or we're in the grace
        // window. A token is valid when it matches the master token OR the client
        // has been approved in the analyzer's "Apparaten" list. An unknown token
        // isn't a dead-end: it's filed in the pending queue for one-tap approval.
        // /settings carries secrets (API keys, Last.fm session, Qobuz password) so
        // it is ALWAYS gated — grace mode never applies to it.
        if !path.hasPrefix("/health"), !loopback {
            let sensitive = path.hasPrefix("/settings")
            let provided = Self.headerValue(Self.tokenHeader, in: header)
            let deviceName = Self.headerValue(Self.deviceHeader, in: header) ?? ""
            if let provided {
                let valid = Self.constantTimeEquals(provided, Self.currentToken())
                    || Self.isApprovedDevice(provided)
                if !valid {
                    Self.recordPending(token: provided, name: deviceName, ip: peerIP)
                    Log.warning("share-server: rejected \(method) \(path) — unapproved device ‘\(deviceName.isEmpty ? "?" : deviceName)’ (\(peerIP)); approve it under Apparaten", category: .network)
                    return ("401 Unauthorized", Data("unauthorized; awaiting approval".utf8), "text/plain")
                }
            } else {
                if Self.enforceToken || sensitive {
                    let why = sensitive ? "secrets endpoint requires a token" : "pair this client via Apparaten"
                    Log.warning("share-server: rejected \(method) \(path) — no token; \(why)", category: .network)
                    return ("401 Unauthorized", Data("unauthorized".utf8), "text/plain")
                }
                Log.warning("share-server: serving \(method) \(path) WITHOUT a token (grace mode) — pair clients, then enable enforcement in Settings", category: .network)
            }
        }

        if method == "POST", path.hasPrefix("/command") {
            let ok = await RoonClient.shared.runRemoteCommandData(body)
            return ok ? ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
                      : ("400 Bad Request", Data("bad command".utf8), "text/plain")
        }
        if method == "POST", path.hasPrefix("/track-feedback") {
            guard let fb = try? JSONDecoder().decode(TrackFeedback.self, from: body), !fb.matchKey.isEmpty else {
                return ("400 Bad Request", Data("bad feedback".utf8), "text/plain")
            }
            do {
                if let kind = fb.kind, !kind.isEmpty {
                    try await database.setFeedback(matchKey: fb.matchKey, title: fb.title, artist: fb.artist, kind: kind)
                } else {
                    try await database.clearFeedback(matchKey: fb.matchKey)
                }
                return ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
            } catch {
                return ("500 Internal Server Error", Data("feedback failed".utf8), "text/plain")
            }
        }
        if path.hasPrefix("/feedback") {
            if let entries = try? await database.allFeedback(),
               let body = try? JSONEncoder().encode(entries) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("feedback failed".utf8), "text/plain")
        }
        // Saved playlists live on the server-of-record so every client app sees
        // the same set (was client-local — each device kept its own).
        if method == "POST", path == "/playlists" {
            guard let req = try? JSONDecoder().decode(SavePlaylistRequest.self, from: body),
                  !req.name.isEmpty else {
                return ("400 Bad Request", Data("bad playlist".utf8), "text/plain")
            }
            if let id = try? await database.savePlaylist(name: req.name, tracks: req.tracks) {
                return ("200 OK", Data("{\"id\":\(id)}".utf8), "application/json")
            }
            return ("500 Internal Server Error", Data("save failed".utf8), "text/plain")
        }
        if method == "DELETE", path == "/playlists" {
            guard let id = Int64(Self.queryValue("id", in: target) ?? "") else {
                return ("400 Bad Request", Data("bad id".utf8), "text/plain")
            }
            if (try? await database.deletePlaylist(id: id)) != nil {
                return ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
            }
            return ("500 Internal Server Error", Data("delete failed".utf8), "text/plain")
        }
        if method == "GET", path == "/playlists" {
            if let summaries = try? await database.listPlaylists(),
               let body = try? JSONEncoder().encode(summaries) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("playlists failed".utf8), "text/plain")
        }
        if path.hasPrefix("/playlist-tracks") {
            guard let id = Int64(Self.queryValue("id", in: target) ?? "") else {
                return ("400 Bad Request", Data("bad id".utf8), "text/plain")
            }
            if let tracks = try? await database.playlistTracks(id: id),
               let body = try? JSONEncoder().encode(tracks) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("playlist tracks failed".utf8), "text/plain")
        }
        if path.hasPrefix("/playback") {
            let zone = Self.queryValue("zone", in: target)
            let data = await RoonClient.shared.snapshotData(forZone: zone)
            return ("200 OK", data, "application/json")
        }
        if path.hasPrefix("/library") {
            let sig = ((try? database.syncStateValue(forKey: "last_sync")) ?? nil) ?? ""
            libCacheLock.lock()
            if let c = libraryCache, c.sig == sig { let d = c.data; libCacheLock.unlock(); return ("200 OK", d, "application/json") }
            libCacheLock.unlock()
            if let body = try? await database.exportLibraryJSON() {
                libCacheLock.lock(); libraryCache = (sig, body); libCacheLock.unlock()
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("export failed".utf8), "text/plain")
        }
        if path.hasPrefix("/history") {
            if let snap = try? await database.listenSnapshot(),
               let body = try? JSONEncoder().encode(snap) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("history failed".utf8), "text/plain")
        }
        // Track-level play stats (content key → count + last played). Thin clients
        // have no local `listening_history`, so Sonic DNA and the personal taste
        // vector pull these from here. `since` (ISO8601) restricts the window.
        if path.hasPrefix("/play-stats") {
            let since = Self.queryValue("since", in: target)
            if let rows = try? await database.playStatsByMatchKey(since: since) {
                let stats = rows.map { SonicDNA.PlayStat(matchKey: $0.matchKey, count: $0.count, lastPlayed: $0.lastPlayed) }
                if let body = try? JSONEncoder().encode(stats) {
                    return ("200 OK", body, "application/json")
                }
            }
            return ("500 Internal Server Error", Data("play-stats failed".utf8), "text/plain")
        }
        if path.hasPrefix("/taste-analysis") {
            if let analysis = try? await database.tasteAnalysis(),
               let body = try? JSONEncoder().encode(analysis) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("taste-analysis failed".utf8), "text/plain")
        }
        if path.hasPrefix("/year-review") {
            let year = Int(Self.queryValue("year", in: target) ?? "") ?? Calendar.current.component(.year, from: Date())
            if let stats = try? await database.yearInReview(year: year),
               let body = try? JSONEncoder().encode(stats) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("year-review failed".utf8), "text/plain")
        }
        if path.hasPrefix("/settings") {
            if let body = try? JSONEncoder().encode(SyncableSettings.exportCurrent()) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("export failed".utf8), "text/plain")
        }
        if path.hasPrefix("/artist-radios") {
            let raw = Self.queryValue("category", in: target) ?? "artist"
            // "all" → every radio currently mirrored to Qobuz, across all categories.
            if raw == "all" {
                return ("200 OK", await RoonClient.shared.mirroredRadiosData(), "application/json")
            }
            let category = RoonClient.RadioCategory(rawValue: raw) ?? .artist
            let data = await RoonClient.shared.artistRadiosData(category: category)
            return ("200 OK", data, "application/json")
        }
        // "Ontdek Wekelijks" — the library-first weekly discovery playlist (see
        // RoonClient+DiscoverWeekly). GET serves the latest built playlist (or null);
        // POST .../refresh rebuilds this week now and returns the fresh set. The
        // refresh prefix is checked FIRST (it also matches "/discover-weekly").
        if method == "POST", path.hasPrefix("/discover-weekly/refresh") {
            let pl = await RoonClient.shared.refreshDiscoverWeekly()
            return ("200 OK", (try? JSONEncoder().encode(pl)) ?? Data("null".utf8), "application/json")
        }
        if path.hasPrefix("/discover-weekly") {
            return ("200 OK", await RoonClient.shared.discoverWeeklyData(), "application/json")
        }
        // Discovery engine (see RoonClient+Discovery). accept/play/reject run the
        // side-effects against the server's live Roon+Qobuz session; run kicks a
        // detached pipeline pass; recommendations/run-status serve the feed.
        if method == "POST",
           path.hasPrefix("/discovery/accept") || path.hasPrefix("/discovery/play") || path.hasPrefix("/discovery/reject") {
            let ok = await RoonClient.shared.handleDiscoveryAction(path, body: body)
            return ok ? ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
                      : ("400 Bad Request", Data("bad discovery action".utf8), "text/plain")
        }
        if method == "POST", path.hasPrefix("/discovery/run") {
            // F12a: an optional mood seed rides along in the body. Absent/
            // undecodable body → nil mood, identical to the pre-F12a behaviour.
            let mood = (try? JSONDecoder().decode(RoonClient.DiscoveryRunRequest.self, from: body))?.mood
            await RoonClient.shared.runDiscoveryNow(mood: mood)
            return ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
        }
        if path.hasPrefix("/discovery/run-status") {
            return ("200 OK", await RoonClient.shared.discoveryRunStatusData(), "application/json")
        }
        if path.hasPrefix("/discovery/recommendations") {
            let kind = RecommendationKind(rawValue: Self.queryValue("kind", in: target) ?? "all")  // nil = all
            let limit = Int(Self.queryValue("limit", in: target) ?? "") ?? 60
            return ("200 OK", await RoonClient.shared.discoveryRecommendationsData(kind: kind, limit: limit), "application/json")
        }
        if path.hasPrefix("/discovery/stats") {
            return ("200 OK", await RoonClient.shared.discoveryStatsData(), "application/json")
        }
        if path.hasPrefix("/discovery/digest-status") {
            return ("200 OK", await RoonClient.shared.discoveryDigestStatusData(), "application/json")
        }
        if path.hasPrefix("/health") {
            let n = (try? await database.trackCount()) ?? 0
            return ("200 OK", Data("{\"status\":\"ok\",\"tracks\":\(n)}".utf8), "application/json")
        }
        return ("404 Not Found", Data("not found".utf8), "text/plain")
    }

    // MARK: - Tiny HTTP parse helpers

    private static func rangeOfHeaderEnd(_ data: Data) -> Range<Data.Index>? {
        let marker = Data("\r\n\r\n".utf8)
        return data.range(of: marker)
    }

    static func contentLength(_ header: String) -> Int {
        for line in header.split(separator: "\r\n") {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                let n = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
                // Clamp: a negative or overflowing value would invert the body
                // slice range and trap. 32 MB is far above any real command body.
                return max(0, min(n, 32 * 1024 * 1024))
            }
        }
        return 0
    }

    /// Constant-time string compare — plain `==`/`!=` short-circuits on the first
    /// differing byte, leaking the match length via timing. Used for the token.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        var diff = UInt8(ab.count == bb.count ? 0 : 1)
        for i in 0..<Swift.max(ab.count, bb.count) {
            let x = i < ab.count ? ab[i] : 0
            let y = i < bb.count ? bb[i] : 0
            diff |= (x ^ y)
        }
        return diff == 0
    }

    static func headerValue(_ name: String, in header: String) -> String? {
        let lname = name.lowercased()
        for line in header.split(separator: "\r\n") {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == lname {
                let v = kv[1].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// True when the connecting peer is on this machine (127.0.0.0/8, ::1, the
    /// v4-mapped loopback, or "localhost"). Such callers skip the token check.
    private static func endpointIsLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let addr):
            return addr.rawValue.first == 127
        case .ipv6(let addr):
            let b = [UInt8](addr.rawValue)
            guard b.count == 16 else { return false }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }   // ::1
            if b[10] == 0xff, b[11] == 0xff, b[12] == 127 { return true }        // ::ffff:127.x.x.x
            return false
        case .name(let name, _):
            return name == "localhost"
        @unknown default:
            return false
        }
    }

    /// Human-readable host/IP of the connecting peer, for the approval list.
    static func endpointHost(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "" }
        switch host {
        case .ipv4(let addr):
            return dottedIPv4([UInt8](addr.rawValue))
        case .ipv6(let addr):
            // IPv4-mapped (::ffff:a.b.c.d) reads nicer as its v4 form.
            let b = [UInt8](addr.rawValue)
            if b.count == 16, b[10] == 0xff, b[11] == 0xff {
                return dottedIPv4(Array(b[12..<16]))
            }
            return addr.debugDescription
        case .name(let name, _):
            return name
        @unknown default:
            return ""
        }
    }

    private static func dottedIPv4(_ b: [UInt8]) -> String {
        b.count == 4 ? "\(b[0]).\(b[1]).\(b[2]).\(b[3])" : ""
    }

    private static func queryValue(_ name: String, in target: String) -> String? {
        guard let q = target.split(separator: "?").dropFirst().first else { return nil }
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == name {
                return kv[1].removingPercentEncoding ?? String(kv[1])
            }
        }
        return nil
    }
}
