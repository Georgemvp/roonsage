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

    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var zones: [Zone] = []
    public private(set) var isSyncing = false
    public private(set) var syncProgress = SyncProgress(phase: "", albumsCompleted: 0, albumsTotal: 0, tracksFound: 0)
    public private(set) var trackCount = 0
    public private(set) var coreHost: String?
    public private(set) var corePort: UInt16 = 9330
    public private(set) var selectedZoneID: String?

    public var selectedZone: Zone? {
        if let id = selectedZoneID, let z = zoneMap[id] { return z }
        return zones.first(where: { $0.state == .playing }) ?? zones.first
    }

    // MARK: - Private

    private let transport = RoonTransport()
    private var zoneMap: [String: Zone] = [:]
    private var syncTask: Task<Void, Never>?
    private var lastNowPlaying: [String: String] = [:]  // zoneID → title (dedup guard)

    // Services — initialised after connection is confirmed
    private var transportService: TransportService?
    private var browseService: BrowseService?
    public private(set) var database: DatabaseManager?
    private var syncService: LibrarySyncService?

    public init() {
        database = try? DatabaseManager(url: Self.databaseURL)
        refreshTrackCount()
    }

    // MARK: - Database URL

    private static var databaseURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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
        RoonClientAuth.clearCredentials()
        await disconnect()
    }

    // MARK: - Transport controls (exposed to UI)

    public func playPause(zoneID: String) async {
        _ = try? await transportService?.control(.playpause, zoneID: zoneID)
    }

    public func next(zoneID: String) async {
        _ = try? await transportService?.control(.next, zoneID: zoneID)
    }

    public func previous(zoneID: String) async {
        _ = try? await transportService?.control(.previous, zoneID: zoneID)
    }

    public func setVolume(outputID: String, value: Int) async {
        _ = try? await transportService?.changeVolume(outputID: outputID, how: "absolute", value: value)
    }

    public func adjustVolume(outputID: String, delta: Int) async {
        _ = try? await transportService?.changeVolume(outputID: outputID, how: "relative", value: delta)
    }

    public func toggleMute(outputID: String, muted: Bool) async {
        _ = try? await transportService?.mute(outputID: outputID, muted: muted)
    }

    public func setShuffle(zoneID: String, enabled: Bool) async {
        _ = try? await transportService?.setShuffle(zoneID: zoneID, enabled: enabled)
    }

    public func setRepeat(zoneID: String, mode: String) async {
        let rMode = TransportService.RepeatMode(rawValue: mode) ?? .off
        _ = try? await transportService?.setRepeat(zoneID: zoneID, mode: rMode)
    }

    /// Play a list of tracks by their Roon item_keys using the browse API.
    /// First track plays immediately; subsequent tracks are queued.
    public func curateTracks(_ tracks: [TrackRecord], zoneID: String) async {
        guard let browse = browseService else { return }
        var isFirst = true
        for track in tracks {
            try? await browse.playByBrowse(itemKey: track.id, zoneID: zoneID, action: isFirst ? "play_now" : "queue")
            isFirst = false
        }
    }

    // MARK: - Library queries (for UI + MCP)

    public func filterTracks(options: DatabaseManager.FilterOptions) -> [TrackRecord] {
        (try? database?.filterTracks(options: options)) ?? []
    }

    public func libraryStats() -> DatabaseManager.LibraryStats? {
        try? database?.libraryStats()
    }

    public func recentListens(limit: Int = 50) -> [DatabaseManager.ListenEntry] {
        (try? database?.recentListens(limit: limit)) ?? []
    }

    public func topArtistsListened(limit: Int = 20) -> [(artist: String, count: Int)] {
        (try? database?.topArtistsListened(limit: limit)) ?? []
    }

    public func totalListens() -> Int {
        (try? database?.totalListens()) ?? 0
    }

    public func imageURL(forKey key: String, size: Int = 200) -> URL? {
        guard let host = coreHost else { return nil }
        return URL(string: "http://\(host):\(corePort)/api/image/\(key)?width=\(size)&height=\(size)&scale=fit")
    }

    public func selectZone(_ id: String) {
        selectedZoneID = id
    }

    // MARK: - Library sync

    public func startSync() {
        guard !isSyncing, let browse = browseService, let db = database else { return }
        let service = LibrarySyncService(browse: browse, database: db)
        syncService = service
        isSyncing = true
        syncProgress = SyncProgress(phase: "Starting…", albumsCompleted: 0, albumsTotal: 0, tracksFound: 0)

        syncTask = Task {
            defer { isSyncing = false }
            do {
                let count = try await service.sync { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.syncProgress = SyncProgress(
                            phase: progress.phase,
                            albumsCompleted: progress.albumsCompleted,
                            albumsTotal: progress.albumsTotal,
                            tracksFound: progress.tracksFound
                        )
                    }
                }
                trackCount = count
                syncProgress = SyncProgress(phase: "Done — \(count) tracks", albumsCompleted: 0, albumsTotal: 0, tracksFound: count)
            } catch {
                syncProgress = SyncProgress(phase: "Error: \(error.localizedDescription)", albumsCompleted: 0, albumsTotal: 0, tracksFound: 0)
            }
        }
    }

    public func cancelSync() {
        syncTask?.cancel()
        let service = syncService
        Task { await service?.cancel() }
        isSyncing = false
    }

    public func searchTracks(query: String) -> [TrackRecord] {
        (try? database?.searchTracks(query: query, limit: 300)) ?? []
    }

    public func searchAlbums(query: String) -> [DatabaseManager.AlbumResult] {
        (try? database?.searchAlbums(query: query)) ?? []
    }

    public func transferZone(fromZoneID: String, toZoneID: String) async {
        _ = try? await transportService?.transferZone(fromZoneID: fromZoneID, toZoneID: toZoneID)
    }

    // MARK: - Private connection flow

    // MARK: - Saved host (persisted across launches)

    public var savedHost: String? { UserDefaults.standard.string(forKey: "lastRoonHost") }
    public var savedPort: UInt16 {
        let p = UserDefaults.standard.integer(forKey: "lastRoonPort")
        return p > 0 ? UInt16(p) : 9330
    }
    private func persistHost(_ host: String, port: UInt16) {
        UserDefaults.standard.set(host, forKey: "lastRoonHost")
        UserDefaults.standard.set(Int(port), forKey: "lastRoonPort")
    }

    private func handleOpen(host: String) async {
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
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    private func handleClose() async {
        transportService = nil
        browseService = nil
        coreHost = nil
        connectionState = .disconnected
        zones = []
        zoneMap = [:]
    }

    private func subscribeZones() async {
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

    private func applyZoneUpdate(_ body: [String: Any]) async {
        let toUpdate = (body["zones_changed"] as? [[String: Any]])
            ?? (body["zones_added"]   as? [[String: Any]])
            ?? (body["zones"]         as? [[String: Any]]) ?? []
        let toRemove = body["zones_removed"] as? [String] ?? []

        for dict in toUpdate {
            let zone = Zone(from: dict)

            // Log a listen when now-playing changes on a playing zone
            if zone.state == .playing, let np = zone.nowPlaying {
                let key = zone.id
                if lastNowPlaying[key] != np.title {
                    lastNowPlaying[key] = np.title
                    try? database?.logListen(
                        title: np.title,
                        artist: np.artist,
                        album: np.album,
                        zoneID: zone.id,
                        zoneName: zone.displayName
                    )
                    if let token = KeychainStore.load(key: "listenbrainz_token"), !token.isEmpty {
                        let title = np.title; let artist = np.artist; let album = np.album
                        Task { await ListenBrainzClient.shared.submit(title: title, artist: artist, album: album, token: token) }
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

    private func refreshTrackCount() {
        trackCount = (try? database?.trackCount()) ?? 0
    }
}

