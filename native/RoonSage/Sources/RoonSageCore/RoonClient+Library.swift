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

    /// Full-table aggregates (COUNT DISTINCT, GROUP BY) — must not block main.
    public func libraryStats() async -> DatabaseManager.LibraryStats? {
        guard let db = database else { return nil }
        return await Task.detached { try? db.libraryStats() }.value
    }

    public func recentListens(limit: Int = 50) async -> [DatabaseManager.ListenEntry] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.recentListens(limit: limit)) ?? [] }.value
    }

    public func topArtistsListened(limit: Int = 20) async -> [(artist: String, count: Int)] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.topArtistsListened(limit: limit)) ?? [] }.value
    }

    public func totalListens() async -> Int {
        guard let db = database else { return 0 }
        return await Task.detached { (try? db.totalListens()) ?? 0 }.value
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
        syncProgress = SyncProgress(phase: "Starten…", albumsCompleted: 0, albumsTotal: 0, tracksFound: 0)

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
                syncProgress = SyncProgress(phase: "Klaar — \(count) tracks", albumsCompleted: 0, albumsTotal: 0, tracksFound: count)
                refreshGenreCount()
                // Track rows (incl. match_key) may have changed → sonic cache is stale.
                await sonicCache.invalidate()
            } catch {
                syncProgress = SyncProgress(phase: "Fout: \(error.localizedDescription)", albumsCompleted: 0, albumsTotal: 0, tracksFound: 0)
            }
        }
    }

    public func cancelSync() {
        syncTask?.cancel()
        let service = syncService
        Task { await service?.cancel() }
        isSyncing = false
    }

    public func startGenreSync() {
        guard !isGenreSyncing, !isSyncing, let browse = browseService, let db = database else { return }
        let service = LibrarySyncService(browse: browse, database: db)
        genreSyncService = service
        isGenreSyncing = true
        genreTask = Task {
            defer { isGenreSyncing = false }
            do {
                try await service.syncGenresOnly { [weak self] phase in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        syncProgress = SyncProgress(phase: phase, albumsCompleted: 0, albumsTotal: 0, tracksFound: trackCount)
                    }
                }
            } catch {
                syncProgress = SyncProgress(phase: "Genre sync fout: \(error.localizedDescription)", albumsCompleted: 0, albumsTotal: 0, tracksFound: trackCount)
            }
            refreshGenreCount()
        }
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

    /// Scans + JSON-parses the whole feature table — must not block main.
    public func topTags(limit: Int = 30) async -> [(tag: String, count: Int)] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.topTags(limit: limit)) ?? [] }.value
    }

    /// Play a single library track by id to a zone (first plays now).
    public func playTrack(id: String, title: String, artist: String?, zoneID: String) async {
        await curateTracks([TrackRecord(id: id, title: title, artist: artist)], zoneID: zoneID)
    }

    /// Add tracks to the queue without interrupting playback. `next: true` uses
    /// Roon's "Add Next" instead of "Queue" (end of queue).
    public func queueTracks(_ tracks: [TrackRecord], next: Bool = false, zoneID: String) async {
        guard let browse = browseService else {
            lastActionError = ActionError(message: "Wachtrij mislukt — geen verbinding met Roon.")
            return
        }
        let action = next ? "add_next" : "queue"
        var failed = 0
        for track in tracks {
            do {
                try await browse.playByBrowse(
                    itemKey: track.id, title: track.title, artist: track.artist,
                    zoneID: zoneID, action: action)
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            lastActionError = ActionError(
                message: failed == tracks.count
                    ? "Wachtrij mislukt — geen van de \(tracks.count) tracks kon worden toegevoegd."
                    : "\(failed) van de \(tracks.count) tracks konden niet in de wachtrij.")
        }
    }

    // MARK: - LLM request analysis (shared by Generate & Recommend)

    public struct RequestFilters: Sendable {
        public var genres: [String]
        public var decades: [Int]
        public var keywords: String
    }

    /// LLM stage 1: map a free-text request to genres (from the library's actual
    /// genres) + decades + keywords. When genre data is unavailable, still extracts
    /// keywords/decades so the candidate pool is at least keyword-filtered.
    public func analyzeForFilters(request: String) async -> RequestFilters {
        let available = (await libraryStats())?.topGenres.map { $0.genre } ?? []
        let config = LLMConfigStore.load()

        if available.isEmpty {
            // No genre data yet — fall back to keywords + decades only so the
            // candidate pool isn't a random whole-library shuffle.
            let system = """
            Extract search keywords from a music request. \
            Respond with ONLY a JSON object, no prose: {"decades": [], "keywords": ""} \
            - decades: 0-3 decade start years like 1980 if an era is implied, else []. \
            - keywords: 1-3 short English search terms capturing the mood/genre, or "".
            """
            guard let resp = try? await LLMClient.shared.complete(system: system, user: "Request: \(request)", config: config),
                  let obj = Self.firstJSONObject(resp) else {
                return RequestFilters(genres: [], decades: [], keywords: "")
            }
            let decades = (obj["decades"] as? [Any])?.compactMap { ($0 as? Int) ?? Int(String(describing: $0)) } ?? []
            let keywords = (obj["keywords"] as? String) ?? ""
            return RequestFilters(genres: [], decades: decades, keywords: keywords)
        }

        var canonical: [String: String] = [:]
        for g in available { canonical[g.lowercased()] = g }

        let genreList = available.prefix(40).joined(separator: ", ")
        let system = """
        You map a music request to library filters. Respond with ONLY a JSON object, no prose: \
        {"genres": [], "decades": [], "keywords": ""} \
        - genres: 0-6 names chosen EXACTLY from the available list that fit the request. Empty = no genre constraint. \
        - decades: 0-3 decade start years like 1980 if an era is implied, else []. \
        - keywords: short extra search terms, or "". \
        Available genres: \(genreList)
        """
        guard let resp = try? await LLMClient.shared.complete(system: system, user: "Request: \(request)", config: config),
              let obj = Self.firstJSONObject(resp) else {
            // LLM unreachable — fall back to direct genre-name substring match.
            // "jazzy" contains "jazz" which matches genre "Jazz" without an LLM.
            let requestLower = request.lowercased()
            let matched = canonical.compactMap { key, value in requestLower.contains(key) ? value : nil }
            return RequestFilters(genres: matched, decades: [], keywords: "")
        }
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
        // Keywords from the LLM are often multi-word mood phrases ("Smooth, Late Night")
        // that the FTS5 AND-query can't match, yielding 0 results and triggering the
        // whole-library fallback. Only apply keywords when genres are absent.
        opts.keywords = filters.genres.isEmpty ? filters.keywords : ""
        opts.excludeLive = true
        opts.limit = 4000
        var tracks = await filterTracks(options: opts)
        if tracks.count < 30 {
            // Genre filter too narrow — drop genres but keep keywords/decades so
            // the pool stays relevant instead of falling back to the whole library.
            opts.genres = []
            tracks = await filterTracks(options: opts)
        }
        if tracks.count < 30 {
            // Keywords also too narrow — full library fallback.
            opts.decades = []; opts.keywords = ""
            tracks = await filterTracks(options: opts)
        }

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
        albums = Array(albums.prefix(limit))

        // Attach genres so the step-3 LLM can match by vibe rather than artist
        // name alone. No-op when track_genres is empty.
        if let db = database, !albums.isEmpty {
            let keys = albums.map(\.albumKey)
            let genreMap = await Task.detached { (try? db.genresForAlbumKeys(keys)) ?? [:] }.value
            if !genreMap.isEmpty {
                for i in albums.indices {
                    albums[i].genres = genreMap[albums[i].albumKey] ?? []
                }
            }
        }
        return albums
    }

}
