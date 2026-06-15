import AudioAnalysis
import Foundation
import Observation
import RoonProtocol

/// Top-level observable client. Drives UI state and owns the transport actor.
///
/// All mutations happen on the MainActor so SwiftUI observations are safe.
/// The transport actor handles WebSocket I/O on its own executor.
@MainActor
@Observable
public final class RoonClient {

    /// Process-wide instance. App Intents (Siri/Shortcuts, Live Activity
    /// buttons) run in the app process without access to SwiftUI state, so
    /// they need a reachable client. The apps use this same instance.
    public static let shared = RoonClient()

    // MARK: - Connection state

    public enum ConnectionState: Equatable {
        case disconnected
        case discovering
        case connecting(host: String)
        case awaitingAuthorization
        case connected(coreName: String)
        case failed(String)

        public var label: String {
            switch self {
            case .disconnected:              "Niet verbonden"
            case .discovering:               "Zoeken naar Roon Core…"
            case .connecting(let host):      "Verbinden met \(host)…"
            case .awaitingAuthorization:     "Wacht op goedkeuring in Roon…"
            case .connected(let name):       "Verbonden met \(name)"
            case .failed(let msg):           "Fout: \(msg)"
            }
        }

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    // MARK: - Sync state

    public struct SyncProgress: Equatable {
        public var phase: String
        public var albumsCompleted: Int
        public var albumsTotal: Int
        public var tracksFound: Int
        public var fraction: Double { albumsTotal > 0 ? Double(albumsCompleted) / Double(albumsTotal) : 0 }
    }

    // MARK: - Observable state

    public internal(set) var connectionState: ConnectionState = .disconnected
    public internal(set) var zones: [Zone] = []

    /// Last.fm historie-import voortgang (zie `RoonClient+Lastfm`).
    public internal(set) var lastfmImportInProgress = false
    public internal(set) var lastfmImportStatus = ""

    public struct QueueItem: Sendable, Identifiable, Codable {
        public var id: Int
        public var title: String
        public var subtitle: String?
        public var length: Int
        public var imageKey: String?
    }
    public internal(set) var queueItems: [QueueItem] = []
    var queueTask: Task<Void, Never>?
    /// Zone the queue is currently subscribed to (idempotent re-subscribe).
    var queueZoneID: String?

    // MARK: - Control mode (playback proxy)
    /// `.direct` = talk to Roon over the WebSocket (the server build).
    /// `.server` = talk to the RoonSage server over HTTP (the client apps);
    /// no Roon extension is registered. Set once at launch via `useServerMode()`.
    public internal(set) var controlMode: RoonControlMode = .direct
    var isRemote: Bool { controlMode == .server }
    /// Resolved server base URL (e.g. http://10.94.184.22:5767) in server mode.
    var remoteBaseURL: String?
    var remotePollTask: Task<Void, Never>?
    /// Consecutive failed/degraded polls; the UI only drops the connection after
    /// a few in a row so a single blip doesn't bounce to the connect screen.
    var remotePollFailures = 0
    /// Guards against overlapping auto library re-imports while one is running.
    var isImportingFromServer = false
    /// Re-issues the zones subscription when its initial state never arrives.
    var zonesWatchdog: Task<Void, Never>?

    /// Last failed user action — drives a transient toast in the UI. Each
    /// failure gets a fresh `id` so repeated identical messages retrigger
    /// the toast. Transport commands used to swallow errors silently: the
    /// user tapped Play mid-reconnect and nothing happened, with no feedback.
    public struct ActionError: Equatable, Sendable {
        public let id: UUID
        public let message: String
        public init(message: String) {
            self.id = UUID()
            self.message = message
        }
    }
    public internal(set) var lastActionError: ActionError?

    /// Surface a failure from a feature/compute view (DJ set, Sonic DNA, Song
    /// Paths, Music Map, …) in the global error toast, so a failed computation
    /// reads as "something went wrong" instead of a misleading empty state.
    public func reportError(_ message: String) {
        lastActionError = ActionError(message: message)
    }

    /// Run a fire-and-forget user action against the transport service,
    /// surfacing failures (and the not-connected case) via `lastActionError`.
    func runAction(_ label: String, _ op: (TransportService) async throws -> Void) async {
        guard let ts = transportService else {
            lastActionError = ActionError(message: "\(label) mislukt — geen verbinding met Roon.")
            return
        }
        do {
            try await op(ts)
            Log.debug("transport-actie '\(label)' verzonden", category: .roon)
        } catch {
            Log.warning("transport-actie '\(label)' mislukt: \(error)", category: .roon)
            lastActionError = ActionError(message: "\(label) mislukt: \(error.localizedDescription)")
        }
    }
    public internal(set) var isSyncing = false
    public internal(set) var syncProgress = SyncProgress(phase: "", albumsCompleted: 0, albumsTotal: 0, tracksFound: 0)
    public internal(set) var trackCount = 0
    public internal(set) var isGenreSyncing = false
    public internal(set) var genreCount = 0
    public internal(set) var coreHost: String?
    public internal(set) var corePort: UInt16 = 9330
    public internal(set) var selectedZoneID: String?

    public var selectedZone: Zone? {
        if let id = selectedZoneID, let z = zoneMap[id] { return z }
        return zones.first(where: { $0.state == .playing }) ?? zones.first
    }

    // MARK: - Private

    let transport = RoonTransport()
    var zoneMap: [String: Zone] = [:]
    var syncTask: Task<Void, Never>?
    var genreTask: Task<Void, Never>?
    var genreSyncService: LibrarySyncService?
    var lastNowPlaying: [String: String] = [:]  // zoneID → title (dedup guard)

    // Reconnect state
    var intentionalDisconnect = false
    var reconnectAttempt = 0
    var reconnectTask: Task<Void, Never>?
    var attemptHost: String?
    var attemptPort: UInt16 = 9330

    // Services — initialised after connection is confirmed
    var transportService: TransportService?
    var browseService: BrowseService?
    public internal(set) var database: DatabaseManager?
    var syncService: LibrarySyncService?
    /// Cached analyzed library for Sonic features (C4) — invalidated on
    /// feature/library sync.
    let sonicCache = SonicLibraryCache()
    /// Gated, serialised listen-logging + LB/Last.fm scrobbling.
    let scrobbler = ScrobbleCoordinator()
    /// HTTP server other devices import the library from (Settings toggle).
    var shareServer: LibraryShareServer?
    /// Cached signature of the analyzer's feature/embedding state (set by the
    /// analyzer app when it starts serving). Folded into `libraryRevision` so
    /// remotes auto-re-pull when analyses change — WITHOUT a per-poll DB read.
    public var featuresRevision: String = ""

    public init() {
        database = DatabaseManager.open(url: Self.databaseURL)
        refreshTrackCount()
        refreshGenreCount()
        #if os(macOS)
        // Sharing defaults to on so the iPhone can pull library + settings
        // without the user flipping a toggle first; an explicit opt-out (key
        // set to false) is still honoured. Gated to macOS — RoonClient.shared
        // also exists on iOS, which must not start a share server.
        let shareEnabled = UserDefaults.standard.object(forKey: "library_share_enabled") as? Bool ?? true
        if shareEnabled {
            setLibrarySharing(enabled: true)
        }
        #endif
    }

    /// Start/stop the library-share HTTP server (persisted; auto-starts at
    /// launch when enabled). Other devices import via GET /library on port 5767.
    public func setLibrarySharing(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "library_share_enabled")
        if enabled {
            guard shareServer == nil, let db = database else { return }
            let server = LibraryShareServer(database: db)
            try? server.start()
            shareServer = server
        } else {
            shareServer?.stop()
            shareServer = nil
        }
    }

    public var isLibrarySharing: Bool { shareServer != nil }

    // MARK: - Database URL

    /// Database filename. Defaults to `library.db` (used by the server build and
    /// the MCP tool). Client apps set this to a separate file via
    /// `useServerMode()` so a client running on the *same machine* as the server
    /// can't clobber the server's authoritative DB (they share the same
    /// Application Support/RoonSage directory — the path isn't bundle-scoped).
    public static var databaseFileOverride: String?

    static var databaseURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("RoonSage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(databaseFileOverride ?? "library.db")
    }

    // MARK: - Connection

    public func connect(host rawHost: String, port: UInt16 = 9330) async {
        // Server mode: no Roon socket. Treat the host (saved/typed) as the
        // RoonSage server address on the share port; empty host → auto-discover.
        if isRemote {
            let h = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if !h.isEmpty { remoteBaseURL = "http://\(h):\(LibraryShareServer.defaultPort)" }
            await startServerMode(); return
        }
        // Text-field input often carries stray whitespace from copy/paste — a
        // space inside the authority makes URL(string:) return nil, which used
        // to crash the transport's force-unwrap. Sanitise and validate first.
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, URL(string: "ws://\(host):\(port)/api") != nil else {
            connectionState = .failed("Ongeldige host of poort: \(rawHost.debugDescription)")
            return
        }
        intentionalDisconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        attemptHost = host
        attemptPort = port
        coreHost = host
        corePort = port
        connectionState = .connecting(host: host)
        Log.info("connect → ws://\(host):\(port)/api", category: .roon)
        await transport.configure(
            onOpen: { [weak self] in await self?.handleOpen(host: host) },
            onClose: { [weak self] in await self?.handleClose() }
        )
        await transport.connect(host: host, port: port)
    }

    /// For background actions (App Intents): make sure we're connected to the
    /// saved Core, waiting briefly for the handshake. Returns whether a
    /// connection (and thus a controllable zone list) is available.
    public func ensureConnected(timeout: TimeInterval = 6) async -> Bool {
        if connectionState.isConnected { return true }
        if isRemote { await startServerMode() }
        else {
            guard let host = savedHost else { return false }
            await connect(host: host, port: savedPort)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if connectionState.isConnected, !zones.isEmpty { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return connectionState.isConnected
    }

    /// Foreground fast-path. iOS tears down the websocket on suspension;
    /// `handleClose` then schedules a reconnect with exponential backoff (up to
    /// 30 s). When the user reopens the app we don't want to sit out that
    /// backoff — cancel it and reconnect now, so a play tap right after
    /// foregrounding isn't a silent no-op against a dead socket. No-op when
    /// already connected/connecting or the user disconnected on purpose.
    public func reconnectOnForeground() {
        if isRemote { Task { await startServerMode() }; return }
        guard !intentionalDisconnect, let host = savedHost else { return }
        switch connectionState {
        case .disconnected, .failed:
            reconnectAttempt = 0
            Task { await connect(host: host, port: savedPort) }
        default:
            break   // connected / connecting / discovering / awaitingAuthorization
        }
    }

    public func discoverAndConnect() async {
        if isRemote { await startServerMode(); return }
        connectionState = .discovering
        let preferredID = RoonClientAuth.loadCoreID()
        let cores = await SoodDiscovery.discover(coreID: preferredID)
        guard let first = cores.first else {
            connectionState = .failed("Geen Roon Core gevonden op het lokale netwerk.\nControleer of Roon draait.")
            return
        }
        await connect(host: first.host, port: first.httpPort)
    }

    public func disconnect() async {
        intentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        syncTask?.cancel()
        await transport.disconnect()
        transportService = nil
        browseService = nil
        syncService = nil
        connectionState = .disconnected
        zones = []
        zoneMap = [:]
    }

    public func clearAndReauthorize() async {
        intentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        RoonClientAuth.clearCredentials()
        await disconnect()
    }

    // MARK: - Private connection flow

    // MARK: - Saved host (persisted across launches)

    public var savedHost: String? { UserDefaults.standard.string(forKey: "lastRoonHost") }
    public var savedPort: UInt16 {
        let p = UserDefaults.standard.integer(forKey: "lastRoonPort")
        return p > 0 ? UInt16(p) : 9330
    }
    func persistHost(_ host: String, port: UInt16) {
        UserDefaults.standard.set(host, forKey: "lastRoonHost")
        UserDefaults.standard.set(Int(port), forKey: "lastRoonPort")
    }

    func handleOpen(host: String) async {
        reconnectAttempt = 0
        let ts = TransportService(transport: transport)
        let bs = BrowseService(transport: transport)
        transportService = ts
        browseService = bs

        // Load the token OFF the MainActor: KeychainStore.load is a synchronous
        // SecItemCopyMatching that can block (e.g. an access prompt under a
        // changed code signature), which would freeze the MainActor — and with
        // it the share server's /playback. Keep the main thread free.
        let token = await Task.detached { RoonClientAuth.loadToken() }.value
        let payload = RoonClientAuth.registerPayload(existingToken: token)
        let extID = (payload["extension_id"] as? String) ?? "?"
        Log.info("ws open op \(host); registreren als \(extID) (token: \(token == nil ? "geen" : "aanwezig"))", category: .roon)

        if token == nil { connectionState = .awaitingAuthorization }

        do {
            let body = try await transport.register(payload: payload)
            guard let reg = RoonClientAuth.parseRegistration(body) else {
                // Log only the keys — the raw body carries the Roon token, and
                // the log file is meant to be shareable.
                Log.error("registratie-antwoord onbruikbaar; velden: \(body.keys.sorted())", category: .roon)
                connectionState = .failed("Onverwacht registratie-antwoord")
                return
            }
            Log.info("geregistreerd bij \(reg.coreName) (core \(reg.coreID))", category: .roon)
            let previousCoreID = RoonClientAuth.loadCoreID()
            RoonClientAuth.saveToken(reg.token, coreID: reg.coreID)
            persistHost(host, port: corePort)
            connectionState = .connected(coreName: reg.coreName)
            await subscribeZones()
            // A different Core (reinstall / another machine) means the cached
            // library — including every item_key — belongs to a foreign session
            // and won't resolve, so resync from scratch. A *same*-Core restart
            // keeps the cache; stale keys there are handled at play time by the
            // search fallback in BrowseService.playByBrowse (cheaper than a full
            // re-walk on every reconnect).
            let coreChanged = previousCoreID != nil && previousCoreID != reg.coreID
            // Hoisted out of the `||` — its right operand is a non-async autoclosure.
            let hasNullKeys = (try? await database?.hasNullMatchKeys()) == true
            let needsResync = trackCount == 0 || coreChanged || hasNullKeys
            if needsResync { startSync() }
        } catch {
            Log.error("registratie mislukt: \(error.localizedDescription)", category: .roon)
            connectionState = .failed(error.localizedDescription)
        }
    }

    func handleClose() async {
        // Reconnect after any established or authorization-pending connection drop.
        // "awaitingAuthorization" drops can happen over flaky networks (ZeroTier etc.)
        // before the user has a chance to approve; retry so Roon re-shows the prompt.
        let shouldReconnect: Bool
        switch connectionState {
        case .connected:             shouldReconnect = true
        case .awaitingAuthorization: shouldReconnect = true
        default:                     shouldReconnect = false
        }
        let host = attemptHost
        let port = attemptPort
        Log.info("ws gesloten (state \(connectionState.label)); reconnect=\(shouldReconnect)", category: .roon)

        transportService = nil
        browseService = nil
        coreHost = nil
        connectionState = .disconnected
        zones = []
        zoneMap = [:]

        guard !intentionalDisconnect, shouldReconnect, let host else { return }

        // Exponential backoff: 2 → 4 → 8 → 16 → 30s (stays at 30s after that).
        let delays: [UInt64] = [2, 4, 8, 16, 30]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1

        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled, !self.intentionalDisconnect else { return }
            await self.connect(host: host, port: port)
        }
    }

    func subscribeZones() async {
        // A failed zone subscription used to silently give up, leaving Now
        // Playing permanently empty until a full reconnect. Two failure
        // modes, two guards: a throwing send retries after 3s; a subscribe
        // whose initial state never arrives (dropped COMPLETE on a flaky
        // link) is detected by a 10s watchdog that re-issues the
        // subscription. A re-issue uses a fresh subscription_key; should the
        // old stream come alive after all, applyZoneUpdate is idempotent.
        guard let stream = try? await transport.subscribe(
            service: RoonService.transport,
            endpoint: "zones"
        ) else {
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard connectionState.isConnected else { return }
                await subscribeZones()
            }
            return
        }

        zonesWatchdog?.cancel()
        zonesWatchdog = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, connectionState.isConnected, zoneMap.isEmpty else { return }
            await subscribeZones()
        }

        Task {
            for await body in stream {
                zonesWatchdog?.cancel()
                await self.applyZoneUpdate(body)
            }
        }
    }

    // MARK: - Play queue

    /// Subscribe to a zone's play queue. Maintains `queueItems` (initial list +
    /// incremental insert/remove changes from Roon).
    public func startQueue(zoneID: String) {
        queueTask?.cancel()
        queueItems = []
        queueZoneID = zoneID
        queueTask = Task {
            guard let stream = try? await transport.subscribe(
                service: RoonService.transport, endpoint: "queue",
                params: ["zone_or_output_id": zoneID, "max_item_count": 200]
            ) else { return }
            for await body in stream {
                applyQueue(body)
            }
        }
    }

    public func stopQueue() {
        queueTask?.cancel()
        queueTask = nil
        queueItems = []
    }

    public func playFromHere(zoneID: String, queueItemID: Int) async {
        if isRemote { var c = RemoteCommand("playFromHere"); c.zoneID = zoneID; c.queueItemID = queueItemID; await remote(c); return }
        try? await transportService?.playFromHere(zoneID: zoneID, queueItemID: queueItemID)
    }

    func applyQueue(_ body: [String: Any]) {
        if let items = body["items"] as? [[String: Any]] {
            queueItems = items.compactMap(Self.parseQueueItem)
        } else if let changes = body["changes"] as? [[String: Any]] {
            var current = queueItems
            for change in changes {
                let op = change["operation"] as? String
                // A missing index used to default to 0, which would remove or
                // insert at the head of the queue — corrupting the view on a
                // malformed change. Skip changes Roon didn't position.
                guard let index = change["index"] as? Int else { continue }
                if op == "remove" {
                    let count = change["count"] as? Int ?? 0
                    if index < current.count {
                        current.removeSubrange(index..<min(index + count, current.count))
                    }
                } else if op == "insert", let its = change["items"] as? [[String: Any]] {
                    current.insert(contentsOf: its.compactMap(Self.parseQueueItem), at: min(index, current.count))
                }
            }
            queueItems = current
        }
    }

    static func parseQueueItem(_ d: [String: Any]) -> QueueItem? {
        guard let id = d["queue_item_id"] as? Int else { return nil }
        let two = d["two_line"] as? [String: Any]
        let three = d["three_line"] as? [String: Any]
        let title = (three?["line1"] as? String) ?? (two?["line1"] as? String) ?? "Unknown"
        let subtitle = (two?["line2"] as? String) ?? (three?["line2"] as? String)
        return QueueItem(id: id, title: title, subtitle: subtitle,
                         length: d["length"] as? Int ?? 0, imageKey: d["image_key"] as? String)
    }

    func applyZoneUpdate(_ body: [String: Any]) async {
        let toUpdate = (body["zones_changed"] as? [[String: Any]])
            ?? (body["zones_added"]   as? [[String: Any]])
            ?? (body["zones"]         as? [[String: Any]]) ?? []
        let toRemove = body["zones_removed"] as? [String] ?? []

        // Roon emits `zones_seek_changed` roughly once per second per playing
        // zone. We don't consume those frames (the progress bar advances via a
        // local timer in the view), so a seek-only update carries no structural
        // change. Returning early avoids rebuilding and reassigning the
        // observable `zones` array every second, which would otherwise
        // re-invalidate the whole Now Playing list on every tick.
        if toUpdate.isEmpty && toRemove.isEmpty { return }

        for dict in toUpdate {
            let zone = Zone(from: dict)

            // Log a listen + scrobble when now-playing changes on a playing
            // zone. All IO (Keychain, SQLite, network) runs in the
            // ScrobbleCoordinator actor, which also applies the minimum-play
            // gate — only the dedup guard stays on the MainActor.
            if zone.state == .playing, let np = zone.nowPlaying {
                let key = zone.id
                if lastNowPlaying[key] != np.title {
                    lastNowPlaying[key] = np.title
                    let item = ScrobbleCoordinator.Item(
                        title: np.title, artist: np.artist, album: np.album,
                        length: np.length.map(Double.init),
                        zoneID: zone.id, zoneName: zone.displayName)
                    let db = database
                    Task { await scrobbler.trackChanged(item, database: db) }
                }
            }

            zoneMap[zone.id] = zone
        }
        for id in toRemove {
            lastNowPlaying.removeValue(forKey: id)
            zoneMap.removeValue(forKey: id)
            Task { await scrobbler.zoneRemoved(id) }
        }
        zones = Array(zoneMap.values).sorted { $0.displayName < $1.displayName }
    }

    func refreshTrackCount() {
        guard let db = database else { trackCount = 0; return }
        // Fire-and-forget so init / import paths never block main on SQLite.
        Task { [weak self] in
            let count = (try? await db.trackCount()) ?? 0
            self?.trackCount = count
        }
    }

    func refreshGenreCount() {
        guard let db = database else { genreCount = 0; return }
        Task { [weak self] in
            let count = (try? await db.genreCount()) ?? 0
            self?.genreCount = count
        }
    }
}

