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

    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var zones: [Zone] = []

    public struct QueueItem: Sendable, Identifiable {
        public var id: Int
        public var title: String
        public var subtitle: String?
        public var length: Int
        public var imageKey: String?
    }
    public private(set) var queueItems: [QueueItem] = []
    private var queueTask: Task<Void, Never>?
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

    // Reconnect state
    private var intentionalDisconnect = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var attemptHost: String?
    private var attemptPort: UInt16 = 9330

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

    public func seek(zoneID: String, seconds: Double) async {
        _ = try? await transportService?.seek(zoneID: zoneID, how: "absolute", seconds: seconds)
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

    /// Heavy library reads run off the main actor (GRDB's `pool.read` blocks the
    /// calling thread); the caller `await`s so the UI stays responsive on large
    /// libraries. Light count queries below stay synchronous.
    public func filterTracks(options: DatabaseManager.FilterOptions) async -> [TrackRecord] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.filterTracks(options: options)) ?? [] }.value
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

    public func searchTracks(query: String) async -> [TrackRecord] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.searchTracks(query: query, limit: 300)) ?? [] }.value
    }

    public func searchAlbums(query: String) async -> [DatabaseManager.AlbumResult] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.searchAlbums(query: query)) ?? [] }.value
    }

    public func browseTracks(query: String, tag: String?, limit: Int = 300) async -> [DatabaseManager.LibraryTrackRow] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.browseTracks(query: query, tag: tag, limit: limit)) ?? [] }.value
    }

    public func topTags(limit: Int = 30) -> [(tag: String, count: Int)] {
        (try? database?.topTags(limit: limit)) ?? []
    }

    /// Play a single library track by id to a zone (first plays now).
    public func playTrack(id: String, title: String, artist: String?, zoneID: String) async {
        await curateTracks([TrackRecord(id: id, title: title, artist: artist)], zoneID: zoneID)
    }

    /// Add tracks to the queue without interrupting playback. `next: true` uses
    /// Roon's "Add Next" instead of "Queue" (end of queue).
    public func queueTracks(_ tracks: [TrackRecord], next: Bool = false, zoneID: String) async {
        guard let browse = browseService else { return }
        let action = next ? "add_next" : "queue"
        for track in tracks {
            try? await browse.playByBrowse(itemKey: track.id, zoneID: zoneID, action: action)
        }
    }

    // MARK: - LLM request analysis (shared by Generate & Recommend)

    public struct RequestFilters: Sendable {
        public var genres: [String]
        public var decades: [Int]
        public var keywords: String
    }

    /// LLM stage 1: map a free-text request to genres (from the library's actual
    /// genres) + decades + keywords. Degrades gracefully to no filter.
    public func analyzeForFilters(request: String) async -> RequestFilters {
        let available = libraryStats()?.topGenres.map { $0.genre } ?? []
        guard !available.isEmpty else { return RequestFilters(genres: [], decades: [], keywords: "") }
        let genreList = available.prefix(40).joined(separator: ", ")
        let system = """
        You map a music request to library filters. Respond with ONLY a JSON object, no prose: \
        {"genres": [], "decades": [], "keywords": ""} \
        - genres: 0-6 names chosen EXACTLY from the available list that fit the request. Empty = no genre constraint. \
        - decades: 0-3 decade start years like 1980 if an era is implied, else []. \
        - keywords: short extra search terms, or "". \
        Available genres: \(genreList)
        """
        guard let resp = try? await LLMClient.shared.complete(system: system, user: "Request: \(request)", config: LLMConfigStore.load()),
              let obj = Self.firstJSONObject(resp) else {
            return RequestFilters(genres: [], decades: [], keywords: "")
        }
        var canonical: [String: String] = [:]
        for g in available { canonical[g.lowercased()] = g }
        let genres = (obj["genres"] as? [Any])?.compactMap { ($0 as? String)?.lowercased() }.compactMap { canonical[$0] } ?? []
        let decades = (obj["decades"] as? [Any])?.compactMap { ($0 as? Int) ?? Int(String(describing: $0)) } ?? []
        let keywords = (obj["keywords"] as? String) ?? ""
        return RequestFilters(genres: genres, decades: decades, keywords: keywords)
    }

    private static func firstJSONObject(_ text: String) -> [String: Any]? {
        let clean = text.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        guard let start = clean.firstIndex(of: "{"), let end = clean.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(clean[start...end].utf8))) as? [String: Any]
    }

    /// Distinct albums whose tracks match the filters — a candidate pool for
    /// album-level recommendation. Shuffled so the LLM sees a varied sample.
    public func candidateAlbums(filters: RequestFilters, limit: Int = 60) async -> [DatabaseManager.AlbumResult] {
        var opts = DatabaseManager.FilterOptions()
        opts.genres = filters.genres
        opts.decades = filters.decades
        opts.keywords = filters.keywords
        opts.excludeLive = true
        opts.limit = 4000
        var tracks = await filterTracks(options: opts)
        if tracks.count < 30 { opts.genres = []; opts.decades = []; opts.keywords = ""; tracks = await filterTracks(options: opts) }

        var counts: [String: Int] = [:]
        for t in tracks { if let k = t.albumKey { counts[k, default: 0] += 1 } }
        var seen = Set<String>()
        var albums: [DatabaseManager.AlbumResult] = []
        for t in tracks {
            guard let k = t.albumKey, !k.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k)
            albums.append(DatabaseManager.AlbumResult(
                albumKey: k, album: t.album ?? "", artist: t.artist, year: t.year, trackCount: counts[k] ?? 0,
                imageKey: t.imageKey
            ))
        }
        albums.shuffle()
        return Array(albums.prefix(limit))
    }

    // MARK: - Audio features (synced from the native analyzer)

    public var analyzerURL: String {
        get { UserDefaults.standard.string(forKey: "analyzer_url") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "analyzer_url") }
    }

    public func audioFeaturesStats() -> (total: Int, matched: Int) {
        (try? database?.audioFeaturesStats()) ?? (0, 0)
    }

    /// Pull all features from the analyzer's HTTP endpoint and upsert them.
    /// Returns (rows received, library tracks now matched), or nil on failure.
    public func syncAudioFeatures(from baseURL: String) async -> (received: Int, matched: Int)? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "\(trimmed)/features"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        // Parsing thousands of feature rows, the bulk upsert transaction, and the
        // JOIN-based stats query are all CPU/IO-heavy. Run them off the MainActor
        // so the UI doesn't freeze while a large feature set syncs.
        let db = database
        return await Task.detached { () -> (received: Int, matched: Int)? in
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            let rows = arr.compactMap { o -> DatabaseManager.AudioFeatureRow? in
                guard let mk = o["match_key"] as? String, !mk.isEmpty else { return nil }
                return DatabaseManager.AudioFeatureRow(
                    matchKey: mk,
                    bpm: o["bpm"] as? Double, camelot: o["camelot"] as? String,
                    keyRoot: o["key_root"] as? String, keyMode: o["key_mode"] as? String,
                    energy: o["energy"] as? Double, duration: o["duration"] as? Double,
                    tags: o["tags"] as? String
                )
            }
            try? db?.upsertAudioFeatures(rows)
            let stats = (try? db?.audioFeaturesStats()) ?? (total: 0, matched: 0)
            return (received: rows.count, matched: stats.matched)
        }.value
    }

    // MARK: - DJ sets

    public func buildDJSet(
        count: Int, startBPM: Double, endBPM: Double,
        curve: DJSetBuilder.Curve, tags: [String], excludeLive: Bool = true
    ) -> [DatabaseManager.DJCandidate] {
        let cands = (try? database?.djCandidates(
            minBPM: min(startBPM, endBPM), maxBPM: max(startBPM, endBPM),
            tags: tags, excludeLive: excludeLive
        )) ?? []
        return DJSetBuilder.build(candidates: cands, count: count, startBPM: startBPM, endBPM: endBPM, curve: curve)
    }

    /// Audio features for a now-playing track (by content match key), if synced.
    public func featuresFor(title: String, artist: String?, album: String?) -> (bpm: Double, camelot: String, tags: [String])? {
        database?.featuresForMatchKey(TrackIdentity.matchKey(artist: artist, album: album, title: title))
    }

    /// Build an endless-style mix seeded from a track: harmonically-compatible
    /// tracks within ±12 BPM of the seed, ordered by the DJ-set builder.
    public func buildRadio(title: String, artist: String?, album: String?, count: Int = 25) -> [DatabaseManager.DJCandidate] {
        guard let seed = featuresFor(title: title, artist: artist, album: album), seed.bpm > 0 else { return [] }
        let cands = (try? database?.djCandidates(minBPM: seed.bpm - 12, maxBPM: seed.bpm + 12, tags: [], excludeLive: true)) ?? []
        guard !cands.isEmpty else { return [] }
        return DJSetBuilder.build(candidates: cands, count: count, startBPM: seed.bpm, endBPM: seed.bpm, curve: .flat)
    }

    public func playDJSet(_ set: [DatabaseManager.DJCandidate], zoneID: String) async {
        let tracks = set.map { TrackRecord(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) }
        await curateTracks(tracks, zoneID: zoneID)
    }

    public func saveDJSet(name: String, set: [DatabaseManager.DJCandidate]) {
        let tracks = set.map { TrackRecord(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) }
        _ = savePlaylist(name: name, tracks: tracks)
    }

    // MARK: - Discovery sections

    public func undiscoveredAlbums(limit: Int = 16) async -> [DatabaseManager.AlbumResult] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.undiscoveredAlbums(limit: limit)) ?? [] }.value
    }

    public func forgottenFavorites(days: Int = 60, limit: Int = 20) async -> [TrackRecord] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.forgottenFavorites(days: days, limit: limit)) ?? [] }.value
    }

    public func topTracks(limit: Int = 25) async -> [TrackRecord] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.topTracks(limit: limit)) ?? [] }.value
    }

    /// Filter by `options`, shuffle, and play a random `count`-track mix.
    public func playShuffledMix(options: DatabaseManager.FilterOptions, count: Int, zoneID: String) async {
        var opts = options
        opts.limit = max(opts.limit, 500)
        var pool = await filterTracks(options: opts)
        pool.shuffle()
        let pick = Array(pool.prefix(count))
        guard !pick.isEmpty else { return }
        await curateTracks(pick, zoneID: zoneID)
    }

    /// Play every track of an album by its album_key (first plays, rest queue).
    public func playAlbum(albumKey: String, zoneID: String) async {
        var opts = DatabaseManager.FilterOptions()
        opts.albumKey = albumKey
        opts.excludeLive = false
        opts.limit = 200
        let tracks = await filterTracks(options: opts)
        guard !tracks.isEmpty else { return }
        await curateTracks(tracks, zoneID: zoneID)
    }

    // MARK: - Sonic similarity (Radio / Fingerprint)

    /// Library tracks sonically similar to a seed (tempo, key, energy, tags).
    /// Heavy scan runs off the main actor.
    public func similarTracks(toMatchKey matchKey: String, limit: Int = 30) async -> [SonicEngine.Scored] {
        guard let db = database, !matchKey.isEmpty else { return [] }
        return await Task.detached {
            let lib = (try? db.sonicTracks()) ?? []
            guard let seed = lib.first(where: { $0.matchKey == matchKey }) else { return [] }
            return SonicEngine.similar(to: seed, in: lib, limit: limit)
        }.value
    }

    public func similarTracks(title: String, artist: String?, album: String?, limit: Int = 30) async -> [SonicEngine.Scored] {
        await similarTracks(toMatchKey: TrackIdentity.matchKey(artist: artist, album: album, title: title), limit: limit)
    }

    /// Seed a station from a now-playing track and play the similar set.
    public func playSonicRadio(title: String, artist: String?, album: String?, count: Int = 30, zoneID: String) async {
        let scored = await similarTracks(title: title, artist: artist, album: album, limit: count)
        let tracks = scored.map { TrackRecord(id: $0.track.id, title: $0.track.title, artist: $0.track.artist, album: $0.track.album) }
        guard !tracks.isEmpty else { return }
        await curateTracks(tracks, zoneID: zoneID)
    }

    public struct Fingerprint: Sendable {
        public var profile: SonicEngine.Profile
        public var recommendations: [SonicEngine.Scored]
        public var seedCount: Int
    }

    /// Your "musical DNA": a profile of your most-played analyzed tracks plus
    /// library recommendations closest to that taste. Computed off-main.
    public func sonicFingerprint(seedLimit: Int = 40, recommendCount: Int = 60) async -> Fingerprint? {
        guard let db = database else { return nil }
        return await Task.detached {
            let lib = (try? db.sonicTracks()) ?? []
            guard !lib.isEmpty else { return nil }
            let top = (try? db.topTracks(limit: seedLimit)) ?? []
            let byKey = Dictionary(lib.map { ($0.matchKey, $0) }, uniquingKeysWith: { a, _ in a })
            let seeds = top.compactMap { $0.matchKey.flatMap { byKey[$0] } }
            // Fall back to the loudest/most-typical slice if there's no play history yet.
            let effectiveSeeds = seeds.isEmpty ? Array(lib.prefix(min(40, lib.count))) : seeds
            let profile = SonicEngine.profile(of: effectiveSeeds)
            let recs = SonicEngine.nearest(toSeeds: effectiveSeeds, in: lib, limit: recommendCount)
            return Fingerprint(profile: profile, recommendations: recs, seedCount: effectiveSeeds.count)
        }.value
    }

    /// All analyzed tracks (for the Music Map). Off-main.
    public func sonicLibrary() async -> [DatabaseManager.SonicTrack] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.sonicTracks()) ?? [] }.value
    }

    // MARK: - Qobuz / global search

    /// Search Qobuz (via Roon global search). Returns tracks whose `id` is a
    /// synthetic `qobuz_search::` key; `curateTracks`/`playByBrowse` re-resolve
    /// it with a fresh search at play time.
    public func searchQobuz(query: String, limit: Int = 20) async -> [TrackRecord] {
        guard let bs = browseService else { return [] }
        let results = (try? await bs.searchGlobal(query: query, limit: limit)) ?? []
        return results.map {
            TrackRecord(id: $0.syntheticKey, title: $0.title, artist: $0.artist, album: $0.album)
        }
    }

    // MARK: - Save to Qobuz

    public var qobuzConfigured: Bool {
        !(KeychainStore.load(key: "qobuz_email") ?? "").isEmpty
            && !(KeychainStore.load(key: "qobuz_password") ?? "").isEmpty
    }

    /// Save a track list as a Qobuz playlist using the stored credentials.
    /// Returns match counts, or nil if not configured / login failed.
    public func saveToQobuz(name: String, tracks: [TrackRecord]) async -> QobuzClient.SaveResult? {
        guard let email = KeychainStore.load(key: "qobuz_email"), !email.isEmpty,
              let pw = KeychainStore.load(key: "qobuz_password"), !pw.isEmpty else { return nil }
        let pairs = tracks.map { (title: $0.title, artist: $0.artist) }
        return await QobuzClient.shared.savePlaylist(name: name, tracks: pairs, email: email, password: pw)
    }

    // MARK: - Saved playlists

    @discardableResult
    public func savePlaylist(name: String, tracks: [TrackRecord]) -> Int64? {
        try? database?.savePlaylist(name: name, tracks: tracks)
    }

    public func playlists() -> [DatabaseManager.PlaylistSummary] {
        (try? database?.listPlaylists()) ?? []
    }

    public func playlistTracks(id: Int64) async -> [TrackRecord] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.playlistTracks(id: id)) ?? [] }.value
    }

    /// Saved tracks re-resolved to the current library (so album art / item_keys
    /// are populated). Falls back to the stored rows for any that don't resolve.
    public func playlistTracksForDisplay(id: Int64) async -> [TrackRecord] {
        let saved = await playlistTracks(id: id)
        guard !saved.isEmpty else { return [] }
        let resolved = (try? database?.resolveCurrentTracks(saved)) ?? []
        guard resolved.count == saved.count else { return saved }
        return resolved
    }

    public func deletePlaylist(id: Int64) {
        try? database?.deletePlaylist(id: id)
    }

    /// Resolve a saved playlist to current item_keys and play it. Returns the
    /// number of tracks that resolved + started.
    @discardableResult
    public func playPlaylist(id: Int64, zoneID: String) async -> Int {
        let saved = await playlistTracks(id: id)
        guard !saved.isEmpty else { return 0 }
        let current = (try? database?.resolveCurrentTracks(saved)) ?? []
        guard !current.isEmpty else { return 0 }
        await curateTracks(current, zoneID: zoneID)
        return current.count
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

    private func handleClose() async {
        // Capture reconnect context before clearing state.
        // Only reconnect if we had a fully established connection — not on
        // initial connect failures (connecting/awaitingAuthorization states).
        let wasConnected: Bool
        if case .connected = connectionState { wasConnected = true } else { wasConnected = false }
        let host = attemptHost
        let port = attemptPort

        transportService = nil
        browseService = nil
        coreHost = nil
        connectionState = .disconnected
        zones = []
        zoneMap = [:]

        guard !intentionalDisconnect, wasConnected, let host else { return }

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

    private func applyQueue(_ body: [String: Any]) {
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

    private static func parseQueueItem(_ d: [String: Any]) -> QueueItem? {
        guard let id = d["queue_item_id"] as? Int else { return nil }
        let two = d["two_line"] as? [String: Any]
        let three = d["three_line"] as? [String: Any]
        let title = (three?["line1"] as? String) ?? (two?["line1"] as? String) ?? "Unknown"
        let subtitle = (two?["line2"] as? String) ?? (three?["line2"] as? String)
        return QueueItem(id: id, title: title, subtitle: subtitle,
                         length: d["length"] as? Int ?? 0, imageKey: d["image_key"] as? String)
    }

    private func applyZoneUpdate(_ body: [String: Any]) async {
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

    private func refreshTrackCount() {
        trackCount = (try? database?.trackCount()) ?? 0
    }
}

