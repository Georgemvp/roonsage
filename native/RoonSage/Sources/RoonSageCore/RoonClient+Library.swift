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
        return (try? await db.filterTracks(options: options)) ?? []
    }

    /// Full-table aggregates (COUNT DISTINCT, GROUP BY) — must not block main.
    public func libraryStats() async -> DatabaseManager.LibraryStats? {
        guard let db = database else { return nil }
        return try? await db.libraryStats()
    }

    /// Full genre vocabulary (most-used first) for mapping a request to filters.
    public func allGenres(limit: Int = 200) async -> [String] {
        guard let db = database else { return [] }
        return (try? await db.allGenres(limit: limit)) ?? []
    }

    public func recentListens(limit: Int = 50) async -> [DatabaseManager.ListenEntry] {
        guard let db = database else { return [] }
        return (try? await db.recentListens(limit: limit)) ?? []
    }

    public func topArtistsListened(limit: Int = 20) async -> [(artist: String, count: Int)] {
        guard let db = database else { return [] }
        return (try? await db.topArtistsListened(limit: limit)) ?? []
    }

    public func totalListens() async -> Int {
        guard let db = database else { return 0 }
        return (try? await db.totalListens()) ?? 0
    }

    /// Combined taste-profile data (total plays + top artists + recent listens).
    /// In thin-client mode the local `client-library.db` has no listening history
    /// (only `tracks`/`track_genres` are synced), so pull it live from the server.
    /// Returns nil on a transient fetch failure so callers keep their last-known
    /// data instead of flashing the empty state.
    public func tasteProfile(topLimit: Int = 50, recentLimit: Int = 100) async -> DatabaseManager.ListenSnapshot? {
        if isRemote {
            guard let base = remoteBaseURL, let url = URL(string: "\(base)/history") else { return nil }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            authorizeShareRequest(&req)
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let snap = try? JSONDecoder().decode(DatabaseManager.ListenSnapshot.self, from: data)
            else { return nil }
            return snap
        }
        guard let db = database else { return nil }
        return try? await db.listenSnapshot(topLimit: topLimit, recentLimit: recentLimit)
    }

    /// Taste analysis (time-of-day, genres, decades + like/dislike summary).
    /// Like `tasteProfile`, the thin client's history/feedback live on the
    /// server, so pull it from there; the server build reads its own DB. Returns
    /// nil on a transient failure so the view keeps its last-known data.
    public func tasteAnalysis() async -> DatabaseManager.TasteAnalysis? {
        if isRemote {
            guard let base = remoteBaseURL, let url = URL(string: "\(base)/taste-analysis") else { return nil }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            authorizeShareRequest(&req)
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let analysis = try? JSONDecoder().decode(DatabaseManager.TasteAnalysis.self, from: data)
            else { return nil }
            return analysis
        }
        guard let db = database else { return nil }
        return try? await db.tasteAnalysis()
    }

    /// Year-in-review stats for the given year. Like `tasteProfile`, the thin
    /// client's local `listening_history` is empty, so pull it from the server;
    /// the macOS server reads its own DB. Returns nil on a transient failure so
    /// the view keeps its last-known data instead of flashing the empty state.
    public func yearInReview(year: Int) async -> DatabaseManager.YearStats? {
        if isRemote {
            guard let base = remoteBaseURL,
                  let url = URL(string: "\(base)/year-review?year=\(year)") else { return nil }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            authorizeShareRequest(&req)
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let stats = try? JSONDecoder().decode(DatabaseManager.YearStats.self, from: data)
            else { return nil }
            return stats
        }
        guard let db = database else { return nil }
        return try? await db.yearInReview(year: year)
    }

    public func imageURL(forKey key: String, size: Int = 200) -> URL? {
        guard let host = coreHost else { return nil }
        return URL(string: "http://\(host):\(corePort)/api/image/\(key)?width=\(size)&height=\(size)&scale=fit")
    }

    public func selectZone(_ id: String) {
        selectedZoneID = id
        // Persist so the choice survives relaunch (see init restore). An explicit
        // pick is the only thing that should make a "play" action target a zone
        // that isn't already playing.
        UserDefaults.standard.set(id, forKey: "selected_zone_id")
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
            guard let s else { return }
            let h = RoonClient.normalizeHost(s)
            // A client never imports from itself: skip loopback so we don't pick
            // this device's own (legacy) share server.
            if !h.isEmpty, !RoonClient.isLoopback(h) { hosts.append(h) }
        }
        // Bonjour first: it resolves to the server's *current* IP, so it wins over
        // a stale saved host after a DHCP change. The known hosts below stay as a
        // fallback for networks where multicast/Bonjour is blocked.
        for r in await BonjourDiscovery.discover() { hosts.append(r.host) }
        if let h = savedHost { addHost(fromURL: h) }
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
        guard let url = URL(string: "\(trimmed)/library") else { return nil }
        var req = URLRequest(url: url)
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        guard let count = await Task.detached(priority: .userInitiated, operation: {
            try? await db.importLibrary(json: data)
        }).value else { return nil }
        refreshTrackCount()
        refreshGenreCount()
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
        return (try? await db.searchTracks(query: query, limit: 300)) ?? []
    }

    public func searchAlbums(query: String) async -> [DatabaseManager.AlbumResult] {
        guard let db = database else { return [] }
        return (try? await db.searchAlbums(query: query)) ?? []
    }

    public func searchArtists(query: String) async -> [DatabaseManager.ArtistResult] {
        guard let db = database else { return [] }
        return (try? await db.searchArtists(query: query)) ?? []
    }

    public func albumsByArtist(_ name: String) async -> [DatabaseManager.AlbumResult] {
        guard let db = database else { return [] }
        return (try? await db.albumsByArtist(name)) ?? []
    }

    public func tracksForAlbum(_ albumKey: String) async -> [DatabaseManager.LibraryTrackRow] {
        guard let db = database else { return [] }
        return (try? await db.tracksForAlbum(albumKey)) ?? []
    }

    public func browseTracks(query: String, tag: String?, limit: Int = 300,
                             order: DatabaseManager.BrowseOrder = .artist) async -> [DatabaseManager.LibraryTrackRow] {
        guard let db = database else { return [] }
        return (try? await db.browseTracks(query: query, tag: tag, limit: limit, order: order)) ?? []
    }

    /// Library rows for a pre-ranked match-key list (play-stat sorts) —
    /// result preserves the input ranking.
    public func tracksByMatchKeys(_ orderedKeys: [String]) async -> [DatabaseManager.LibraryTrackRow] {
        guard let db = database else { return [] }
        return (try? await db.tracksByMatchKeys(orderedKeys)) ?? []
    }

    /// Scans + JSON-parses the whole feature table — must not block main.
    public func topTags(limit: Int = 30) async -> [(tag: String, count: Int)] {
        guard let db = database else { return [] }
        return (try? await db.topTags(limit: limit)) ?? []
    }

    /// Play a single library track by id to a zone (first plays now).
    public func playTrack(id: String, title: String, artist: String?, zoneID: String) async {
        await curateTracks([TrackRecord(id: id, title: title, artist: artist)], zoneID: zoneID)
    }

    /// Add tracks to the queue without interrupting playback. `next: true` uses
    /// Roon's "Add Next" instead of "Queue" (end of queue).
    public func queueTracks(_ tracks: [TrackRecord], next: Bool = false, zoneID: String) async {
        if isRemote { var c = RemoteCommand("queue"); c.zoneID = zoneID; c.tracks = tracks; c.next = next; await remote(c); return }
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

    /// The analysed scope of a free-text request: which library genres / mood
    /// tags / decades / keywords it maps to. Shared by Generate, Ask and Recommend.
    public struct RequestFilters: Sendable {
        public var genres: [String]
        public var decades: [Int]
        public var keywords: String
        public var tags: [String]

        public init(genres: [String] = [], decades: [Int] = [], keywords: String = "", tags: [String] = []) {
            self.genres = genres
            self.decades = decades
            self.keywords = keywords
            self.tags = tags
        }

        public var isEmpty: Bool {
            genres.isEmpty && decades.isEmpty && keywords.isEmpty && tags.isEmpty
        }

        /// Human-readable Dutch scope line for a result header, e.g.
        /// "Uit Jazz · chill · 1970s (240 kandidaten)".
        public func scopeSummary(poolSize: Int) -> String {
            var parts: [String] = []
            if !genres.isEmpty  { parts.append(genres.joined(separator: ", ")) }
            if !tags.isEmpty    { parts.append(tags.joined(separator: ", ")) }
            if !decades.isEmpty { parts.append(decades.sorted().map { "\($0)s" }.joined(separator: ", ")) }
            if parts.isEmpty, !keywords.isEmpty { parts.append("“\(keywords)”") }
            let scope = parts.isEmpty ? "hele bibliotheek" : parts.joined(separator: " · ")
            return "Uit \(scope) (\(poolSize) kandidaten)"
        }
    }

    /// LLM stage 1 (single source of truth for Generate / Ask / Recommend): map a
    /// free-text request to library genres + mood tags + decades + keywords, each
    /// chosen from what the library actually contains. Uses JSON mode + a low
    /// temperature for faithful, near-deterministic mapping. Degrades gracefully:
    /// substring match when the LLM is unreachable, keywords-only when there's no
    /// genre/tag vocabulary yet.
    public func analyzeForFilters(request: String) async -> RequestFilters {
        let available = await allGenres(limit: 200)
        let availableTags = (await topTags(limit: 60)).map { $0.tag }
        let config = effectiveLLMConfig()

        guard !available.isEmpty || !availableTags.isEmpty else {
            // No vocabulary yet — extract decades + keywords only so the candidate
            // pool isn't a random whole-library shuffle.
            let system = """
            Extract search keywords from a music request. \
            Respond with ONLY a JSON object, no prose: {"decades": [], "keywords": ""} \
            - decades: 0-3 decade start years like 1980 if an era is implied, else []. \
            - keywords: 1-3 short English search terms capturing the mood/genre, or "".
            """
            guard let resp = try? await LLMClient.shared.complete(
                    system: system, user: "Request: \(request)", config: config,
                    jsonMode: true, temperature: 0.2, maxTokens: 256),
                  let obj = Self.firstJSONObject(resp) else {
                return RequestFilters()
            }
            return RequestFilters(decades: Self.parseDecades(obj["decades"]),
                                  keywords: (obj["keywords"] as? String) ?? "")
        }

        // Use the FULL genre vocabulary (not just top-N) so smaller genres stay
        // selectable. Roon's taxonomy is coarse (e.g. one "Jazz"), so the model is
        // told to map sub-styles to their parent; substring matching below is the
        // safety net.
        let genreList = available.prefix(80).joined(separator: ", ")
        let tagLine = availableTags.isEmpty ? ""
            : "\n- tags: 0-5 mood/vibe tags chosen EXACTLY from this list that fit the request: \(availableTags.prefix(50).joined(separator: ", "))"
        let system = """
        You map a music playlist request to library filters. \
        Respond with ONLY a JSON object, no prose: \
        {"genres": [], "decades": [], "keywords": "", "tags": []} \
        - genres: 0-6 names copied VERBATIM from the available list that fit the request's mood/style. The list is the COMPLETE vocabulary — never invent names. Map any sub-style in the request to its closest PARENT in the list (e.g. bebop/swing/smooth jazz/hard bop -> "Jazz"; techno/house -> the closest electronic name; baroque/opera -> "Classical"). Empty = no genre constraint. \
        - decades: 0-3 decade start years like 1980 if an era is implied, else []. \
        - keywords: short extra search terms for title/artist, or "".\(tagLine)
        Available genres: \(genreList)
        """
        guard let resp = try? await LLMClient.shared.complete(
                system: system, user: "Request: \(request)", config: config,
                jsonMode: true, temperature: 0.2, maxTokens: 256),
              let obj = Self.firstJSONObject(resp) else {
            // LLM unreachable — direct genre-name substring match.
            // "jazzy" contains "jazz" which matches genre "Jazz" without an LLM.
            let requestLower = request.lowercased()
            let matched = available.filter { requestLower.contains($0.lowercased()) }
            return RequestFilters(genres: matched)
        }

        // Expand each model-picked genre to every library genre it overlaps with,
        // so "jazz" also pulls in "Vocal Jazz", "Jazz Fusion", etc. (bidirectional
        // substring) — exact equality alone left these out → empty filter → whole-
        // library fallback that ignored the request.
        let picked = (obj["genres"] as? [Any])?.compactMap { ($0 as? String)?.lowercased() } ?? []
        var genres: [String] = []
        var seen = Set<String>()
        for p in picked where !p.isEmpty {
            for g in available {
                let gl = g.lowercased()
                guard gl.contains(p) || p.contains(gl) else { continue }
                if seen.insert(gl).inserted { genres.append(g) }
            }
        }
        let decades = Self.parseDecades(obj["decades"])
        let keywords = (obj["keywords"] as? String) ?? ""
        let tagSet = Set(availableTags.map { $0.lowercased() })
        var seenTags = Set<String>()
        // Dedup tags too (a model may echo "Chill"/"chill") so FilterChips' ForEach
        // ids stay unique.
        let tags = (obj["tags"] as? [Any])?.compactMap { ($0 as? String)?.lowercased() }
            .filter { tagSet.contains($0) && seenTags.insert($0).inserted } ?? []
        return RequestFilters(genres: genres, decades: decades, keywords: keywords, tags: tags)
    }

    static func firstJSONObject(_ text: String) -> [String: Any]? {
        // `complete` already strips reasoning blocks; this is just the brace-
        // matching safety net for models that wrap JSON in prose or code fences.
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }

    /// Robustly parse a JSON "decades" array into floored decade start-years.
    /// Handles Int (1980), Double (1980.0), and numeric strings ("1980"); floors
    /// to the decade boundary and drops anything outside 1900...2030. `Int(String(
    /// describing: 1980.0))` silently returns nil, dropping eras — this doesn't.
    nonisolated static func parseDecades(_ raw: Any?) -> [Int] {
        guard let arr = raw as? [Any] else { return [] }
        var out: [Int] = []
        for v in arr {
            var year: Int?
            if let i = v as? Int { year = i }
            else if let d = v as? Double { year = Int(d) }
            else if let s = v as? String {
                let t = s.trimmingCharacters(in: .whitespaces)
                year = Int(t) ?? Double(t).map(Int.init)
            }
            guard let y = year, y >= 1900, y <= 2030 else { continue }
            let decade = (y / 10) * 10
            if !out.contains(decade) { out.append(decade) }
        }
        return out
    }

    /// Distinct albums whose tracks match the filters — a candidate pool for
    /// album-level recommendation. Shuffled so the LLM sees a varied sample.
    public func candidateAlbums(filters: RequestFilters, limit: Int = 60) async -> [DatabaseManager.AlbumResult] {
        var opts = DatabaseManager.FilterOptions()
        opts.genres = filters.genres
        opts.decades = filters.decades
        opts.tags = filters.tags
        // Keywords from the LLM are often multi-word mood phrases ("Smooth, Late Night")
        // that the FTS5 AND-query can't match, yielding 0 results and triggering the
        // whole-library fallback. Only apply keywords when no genre/tag constraint.
        opts.keywords = (filters.genres.isEmpty && filters.tags.isEmpty) ? filters.keywords : ""
        opts.excludeLive = true
        opts.limit = 4000
        var tracks = await filterTracks(options: opts)
        if tracks.count < 30, !opts.tags.isEmpty {
            // Tags need synced audio features — relax them first.
            opts.tags = []
            tracks = await filterTracks(options: opts)
        }
        if tracks.count < 30, !opts.genres.isEmpty {
            // Genre filter too narrow — drop genres but keep keywords/decades so
            // the pool stays relevant instead of falling back to the whole library.
            opts.genres = []
            tracks = await filterTracks(options: opts)
        }
        if tracks.count < 30 {
            // Everything too narrow — full library fallback.
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
            let genreMap = (try? await db.genresForAlbumKeys(keys)) ?? [:]
            if !genreMap.isEmpty {
                for i in albums.indices {
                    albums[i].genres = genreMap[albums[i].albumKey] ?? []
                }
            }
        }
        return albums
    }

}
