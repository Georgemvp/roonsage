import AudioAnalysis
import Foundation
import Observation
import RoonProtocol

@MainActor
extension RoonClient {
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

    /// Find a Mac that's sharing its library, without typing an address: the
    /// app already knows likely hosts (Roon Core, analyzer, LLM server, last
    /// import) — probe them all on port 5767 concurrently and return the
    /// first base URL whose /health answers. Works over ZeroTier, where
    /// Bonjour/multicast discovery wouldn't.
    public func discoverShareServer() async -> String? {
        var hosts: [String] = []
        func addHost(fromURL s: String?) {
            guard let s, let h = URL(string: s.trimmingCharacters(in: .whitespaces))?.host else { return }
            hosts.append(h)
        }
        if let h = savedHost { hosts.append(h) }
        addHost(fromURL: analyzerURL)
        addHost(fromURL: LLMConfigStore.load().baseURL)
        addHost(fromURL: UserDefaults.standard.string(forKey: "library_import_url"))
        var seen = Set<String>()
        let candidates = hosts.filter { seen.insert($0).inserted }
        guard !candidates.isEmpty else { return nil }

        return await withTaskGroup(of: String?.self) { group in
            for host in candidates {
                group.addTask {
                    let base = "http://\(host):\(LibraryShareServer.defaultPort)"
                    guard let url = URL(string: "\(base)/health") else { return nil }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 2
                    guard let (data, resp) = try? await URLSession.shared.data(for: req),
                          (resp as? HTTPURLResponse)?.statusCode == 200,
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          (obj["tracks"] as? Int ?? 0) > 0 else { return nil }
                    return base
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    /// One-tap import: find the sharing Mac (known hosts on port 5767) and
    /// pull its library. Returns (sourceURL, trackCount), or nil when no
    /// server was found or the import failed.
    public func autoImportLibrary() async -> (source: String, count: Int)? {
        guard let base = await discoverShareServer() else { return nil }
        UserDefaults.standard.set(base, forKey: "library_import_url")
        guard let count = await importLibrary(fromMac: base) else { return nil }
        return (base, count)
    }

    /// Import the full library from another device's share server
    /// (`http://<mac>:5767`) instead of walking Roon Browse locally — the
    /// fast path for first setup on iPhone over ZeroTier. Returns the number
    /// of imported tracks, or nil on failure.
    public func importLibrary(fromMac baseURL: String) async -> Int? {
        // A running sync writes the same tables the import replaces.
        guard let db = database, !isSyncing else { return nil }
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "\(trimmed)/library"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        guard let count = await Task.detached(priority: .userInitiated, operation: {
            try? db.importLibrary(json: data)
        }).value else { return nil }
        refreshTrackCount()
        await sonicCache.invalidate()
        return count
    }

    /// True when a previous sync run was interrupted (app quit or suspended
    /// mid-walk). The next `startSync()` resumes it via album checkpoints
    /// instead of starting over.
    public var hasInterruptedSync: Bool {
        guard !isSyncing, let db = database else { return false }
        return ((try? db.syncStateValue(forKey: "sync_in_progress")) ?? nil) == "1"
    }

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
                // Track rows (incl. match_key) may have changed → sonic cache is stale.
                await sonicCache.invalidate()
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

    static func firstJSONObject(_ text: String) -> [String: Any]? {
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

}
