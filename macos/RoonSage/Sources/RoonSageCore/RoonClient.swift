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
            case .disconnected:              "Disconnected"
            case .discovering:               "Searching for Roon Core…"
            case .connecting(let host):      "Connecting to \(host)…"
            case .awaitingAuthorization:     "Waiting for authorization in Roon…"
            case .connected(let name):       "Connected to \(name)"
            case .failed(let msg):           "Error: \(msg)"
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

    public struct QueueItem: Sendable, Identifiable {
        public var id: Int
        public var title: String
        public var subtitle: String?
        public var length: Int
        public var imageKey: String?
    }
    public internal(set) var queueItems: [QueueItem] = []
    var queueTask: Task<Void, Never>?
    public internal(set) var isSyncing = false
    public internal(set) var syncProgress = SyncProgress(phase: "", albumsCompleted: 0, albumsTotal: 0, tracksFound: 0)
    public internal(set) var trackCount = 0
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

    public init() {
        database = try? DatabaseManager(url: Self.databaseURL)
        refreshTrackCount()
    }

    // MARK: - Database URL

    static var databaseURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("RoonSage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.db")
    }

    // MARK: - Connection

    public func connect(host rawHost: String, port: UInt16 = 9330) async {
        // Text-field input often carries stray whitespace from copy/paste — a
        // space inside the authority makes URL(string:) return nil, which used
        // to crash the transport's force-unwrap. Sanitise and validate first.
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, URL(string: "ws://\(host):\(port)/api") != nil else {
            connectionState = .failed("Invalid host or port: \(rawHost.debugDescription)")
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
        await transport.configure(
            onOpen: { [weak self] in await self?.handleOpen(host: host) },
            onClose: { [weak self] in await self?.handleClose() }
        )
        await transport.connect(host: host, port: port)
    }

    public func discoverAndConnect() async {
        connectionState = .discovering
        let preferredID = RoonClientAuth.loadCoreID()
        let cores = await SoodDiscovery.discover(coreID: preferredID)
        guard let first = cores.first else {
            connectionState = .failed("No Roon Core found on the local network.\nMake sure Roon is running.")
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

        let token = RoonClientAuth.loadToken()
        let payload = RoonClientAuth.registerPayload(existingToken: token)

        if token == nil { connectionState = .awaitingAuthorization }

        do {
            let body = try await transport.register(payload: payload)
            guard let reg = RoonClientAuth.parseRegistration(body) else {
                connectionState = .failed("Unexpected registration response")
                return
            }
            RoonClientAuth.saveToken(reg.token, coreID: reg.coreID)
            persistHost(host, port: corePort)
            connectionState = .connected(coreName: reg.coreName)
            await subscribeZones()
            let needsResync = trackCount == 0 || (try? database?.hasNullMatchKeys()) == true
            if needsResync { startSync() }
        } catch {
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
        guard let stream = try? await transport.subscribe(
            service: RoonService.transport,
            endpoint: "zones"
        ) else { return }

        Task {
            for await body in stream {
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
        try? await transportService?.playFromHere(zoneID: zoneID, queueItemID: queueItemID)
    }

    func applyQueue(_ body: [String: Any]) {
        if let items = body["items"] as? [[String: Any]] {
            queueItems = items.compactMap(Self.parseQueueItem)
        } else if let changes = body["changes"] as? [[String: Any]] {
            var current = queueItems
            for change in changes {
                let op = change["operation"] as? String
                let index = change["index"] as? Int ?? 0
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

            // Log a listen + scrobble when now-playing changes on a playing zone.
            // Keychain reads (SecItemCopyMatching) and the SQLite write are
            // blocking IO; with several zones changing track at once they would
            // otherwise stall the main thread. Do all of it off the MainActor —
            // only the dedup guard below needs to stay here.
            if zone.state == .playing, let np = zone.nowPlaying {
                let key = zone.id
                if lastNowPlaying[key] != np.title {
                    lastNowPlaying[key] = np.title
                    let db = database
                    let zoneID = zone.id
                    let zoneName = zone.displayName
                    Task.detached {
                        try? db?.logListen(
                            title: np.title, artist: np.artist, album: np.album,
                            zoneID: zoneID, zoneName: zoneName
                        )
                        if let token = KeychainStore.load(key: "listenbrainz_token"), !token.isEmpty {
                            await ListenBrainzClient.shared.submit(
                                title: np.title, artist: np.artist, album: np.album, token: token
                            )
                        }
                        if let apiKey = KeychainStore.load(key: "lastfm_api_key"), !apiKey.isEmpty,
                           let secret = KeychainStore.load(key: "lastfm_api_secret"), !secret.isEmpty,
                           let sk = KeychainStore.load(key: "lastfm_session_key"), !sk.isEmpty,
                           let artist = np.artist, !artist.isEmpty {
                            let creds = LastfmClient.Credentials(apiKey: apiKey, apiSecret: secret, sessionKey: sk)
                            let ts = Int(Date().timeIntervalSince1970)
                            await LastfmClient.shared.updateNowPlaying(artist: artist, track: np.title, album: np.album, creds: creds)
                            await LastfmClient.shared.scrobble(artist: artist, track: np.title, album: np.album, timestamp: ts, creds: creds)
                        }
                    }
                }
            }

            zoneMap[zone.id] = zone
        }
        for id in toRemove {
            lastNowPlaying.removeValue(forKey: id)
            zoneMap.removeValue(forKey: id)
        }
        zones = Array(zoneMap.values).sorted { $0.displayName < $1.displayName }
    }

    func refreshTrackCount() {
        trackCount = (try? database?.trackCount()) ?? 0
    }
}

