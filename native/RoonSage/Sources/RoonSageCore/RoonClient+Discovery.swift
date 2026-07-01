import AudioAnalysis
import Foundation

// MARK: - Discovery engine (server run + accept/reject + client fetch)
//
// The outward-facing recommendation engine. On the always-on server build
// (`.direct`) it runs the DiscoveryPipeline daily (+ on demand), stores a batch,
// and executes the accept/play/reject side-effects against the live Roon+Qobuz
// session. The Mac/iOS client apps (`.server`) fetch the ranked feed and POST
// actions over the share server — the same isRemote split as feedback/radios.

extension RoonClient {

    /// The stable Qobuz playlist accepted albums are saved into.
    nonisolated static let discoveryPlaylistName = "Ontdekkingen"
    /// Daily re-run cadence on the server build.
    nonisolated static let discoveryRefreshInterval: UInt64 = 24 * 60 * 60 * 1_000_000_000
    /// Max recommendations kept per batch.
    nonisolated static let discoveryMaxItems = 60

    /// The producers that run each pipeline pass. Ships every Last.fm/MusicBrainz/
    /// ListenBrainz/AI producer; the gated Deezer/Spotify/Discogs producers (each
    /// needs a new client + the user's own account) land later. Public so the
    /// analyzer's tuning settings can list `id`s for the enable/disable toggles
    /// without hand-duplicating them.
    public static var discoveryProducers: [DiscoveryProducer] {
        [SimilarArtistWebProducer(), ChartsProducer(), ReleaseRadarProducer(),
         GapFillProducer(), ArtistRelationshipsProducer(), ListenBrainzRadioProducer(), AIPicksProducer()]
    }

    // MARK: - Tuning (F11) — persisted server-side (this is the analyzer/server
    // build's own UserDefaults; configured from DiscoverySettingsView there, same
    // as the sonic-radio dial). No client push exists (mirrors `/settings` being
    // GET-only) — Mac/iOS just render the resulting feed.

    /// "Veilig ↔ avontuurlijk" — feeds `ScoringWeights.tuned(adventurousness:)`.
    /// Shares `defaultAdventurousness` (0.35) with the radio dial so an untouched
    /// install's first Ontdekkingen run scores close to the old hardcoded `.default`.
    public var discoveryAdventurousness: Double {
        get { (UserDefaults.standard.object(forKey: "discovery_adventurousness") as? Double) ?? Self.defaultAdventurousness }
        set { UserDefaults.standard.set(min(1, max(0, newValue)), forKey: "discovery_adventurousness") }
    }

    /// Producer ids (`DiscoveryProducer.id`) turned off by the user. Empty by
    /// default so an untouched install runs every producer, unchanged.
    public var discoveryDisabledProducers: Set<String> {
        get { Set((UserDefaults.standard.array(forKey: "discovery_disabled_producers") as? [String]) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "discovery_disabled_producers") }
    }

    /// Days a rejected recommendation stays hidden before it's eligible to
    /// resurface. Default 60 (the prior hardcoded value).
    public var discoveryRejectionCooldownDays: Int {
        get { (UserDefaults.standard.object(forKey: "discovery_cooldown_days") as? Int) ?? 60 }
        set { UserDefaults.standard.set(max(0, newValue), forKey: "discovery_cooldown_days") }
    }

    /// The producers to actually run: every shipped producer minus the disabled
    /// ones — unless that would empty the set entirely (a user disabling every
    /// producer would otherwise leave Ontdekkingen permanently blank), in which
    /// case the disable list is ignored for this run.
    var activeDiscoveryProducers: [DiscoveryProducer] {
        let disabled = discoveryDisabledProducers
        guard !disabled.isEmpty else { return Self.discoveryProducers }
        let filtered = Self.discoveryProducers.filter { !disabled.contains($0.id) }
        return filtered.isEmpty ? Self.discoveryProducers : filtered
    }

    // MARK: - Wire DTO

    /// POST body for accept/play/reject.
    public struct DiscoveryActionRequest: Codable, Sendable {
        public var itemID: Int64
        public var zoneID: String?
        public var permanent: Bool?
        public init(itemID: Int64, zoneID: String? = nil, permanent: Bool? = nil) {
            self.itemID = itemID; self.zoneID = zoneID; self.permanent = permanent
        }
    }

    // MARK: - Public API (client + server)

    /// The current recommendation feed (newest complete batch). Server reads its
    /// DB; clients pull `/discovery/recommendations`.
    public func discoveryRecommendations(kind: RecommendationKind? = nil, limit: Int = 60) async -> [RecommendationItemDTO] {
        if isRemote { return await fetchDiscoveryFromServer(kind: kind, limit: limit) }
        guard let db = database else { return [] }
        let rows = (try? await db.latestRecommendationItems(kind: kind, limit: limit)) ?? []
        return rows.map { $0.dto }
    }

    /// Status of the newest batch (for the "Ververs" spinner / empty state).
    public func discoveryRunStatus() async -> DiscoveryRunStatus {
        if isRemote { return await fetchDiscoveryStatusFromServer() }
        return (try? await database?.latestBatchStatus()) ?? DiscoveryRunStatus(status: "idle", itemCount: 0, createdAt: nil)
    }

    /// Aggregate stats for the "Ontdek-inzichten" dashboard. Server reads its DB;
    /// clients pull `/discovery/stats`.
    public func discoveryStats() async -> DiscoveryStatsDTO {
        if isRemote { return await fetchDiscoveryStatsFromServer() }
        return await localDiscoveryStats()
    }

    /// Build the stats DTO from the local DB (server path + the server HTTP helper).
    private func localDiscoveryStats() async -> DiscoveryStatsDTO {
        let now = ISO8601DateFormatter().string(from: Date())
        guard let db = database, let inp = try? await db.discoveryStatsInputs() else {
            return DiscoveryStatsDTO(accepted: 0, rejected: 0, pending: 0, approvalRate: 0,
                                     producers: [], topGenres: [], generatedAt: now)
        }
        return DiscoveryStatsBuilder.build(items: inp.facts, lifetimeAccepted: inp.accepted,
                                           lifetimeRejected: inp.rejected, latestPending: inp.latestPending,
                                           generatedAt: now)
    }

    /// Kick a fresh pipeline run. Server runs it detached; clients POST the trigger.
    public func triggerDiscoveryRun() async {
        if isRemote {
            guard let base = remoteBaseURL, let url = URL(string: "\(base)/discovery/run") else { return }
            var req = URLRequest(url: url); req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("{\"trigger\":\"manual\"}".utf8)
            req.timeoutInterval = 15
            authorizeShareRequest(&req)
            _ = try? await URLSession.shared.data(for: req)
            return
        }
        runDiscoveryNow()
    }

    public func acceptRecommendation(_ id: Int64) async {
        if isRemote { _ = await postDiscoveryAction("/discovery/accept", DiscoveryActionRequest(itemID: id)); return }
        _ = await serverAcceptRecommendation(id)
    }

    public func playRecommendation(_ id: Int64, zoneID: String?) async {
        if isRemote { _ = await postDiscoveryAction("/discovery/play", DiscoveryActionRequest(itemID: id, zoneID: zoneID)); return }
        _ = await serverPlayRecommendation(id, zoneID: zoneID)
    }

    public func rejectRecommendation(_ id: Int64, permanent: Bool = false) async {
        if isRemote { _ = await postDiscoveryAction("/discovery/reject", DiscoveryActionRequest(itemID: id, permanent: permanent)); return }
        _ = await serverRejectRecommendation(id, permanent: permanent)
    }

    // MARK: - Server: pipeline run

    /// Fire-and-forget manual run (server build). Guarded against overlap.
    public func runDiscoveryNow() {
        guard controlMode == .direct else { return }
        Task { [weak self] in _ = await self?.runDiscoveryPipeline(trigger: "manual") }
    }

    /// Assemble the pipeline inputs from the DB + Keychain + feedback, run it, and
    /// store the batch. Returns the new batch id (or nil on skip/failure).
    @discardableResult
    func runDiscoveryPipeline(trigger: String) async -> Int64? {
        guard controlMode == .direct, !discoveryRunning, let db = database else { return nil }
        discoveryRunning = true
        defer { discoveryRunning = false }

        await ensureFeedbackLoaded()

        // Seeds (taste profile).
        let topArtists = ((try? await db.topArtistsListened(limit: 60)) ?? []).map { $0.artist }
        let hints = await feedbackArtistHints()
        let libraryArtists = (try? await db.libraryArtistSet()) ?? []
        let libraryGenres = (try? await db.libraryGenreSet()) ?? []
        let libraryAlbumKeys = (try? await db.libraryAlbumKeySet()) ?? []
        let watchlist = (try? await db.watchlistArtists()) ?? []
        let seeds = DiscoverySeeds(
            topArtists: topArtists, likedArtists: hints.liked, dislikedArtists: hints.disliked,
            libraryArtists: libraryArtists, libraryGenres: libraryGenres, libraryAlbumKeys: libraryAlbumKeys,
            watchlist: watchlist, tasteVector: nil)

        guard !topArtists.isEmpty || !hints.liked.isEmpty || !watchlist.isEmpty else {
            Log.info("Ontdekkingen: nog geen luistergeschiedenis/feedback om op te seeden — overgeslagen", category: .roon)
            return nil
        }

        // Skip-if-unchanged guard: don't re-run the whole MB/LLM-costed pipeline
        // when nothing that could change the output has shifted since the last
        // batch and that batch is still fresh enough for this trigger (scheduled:
        // 6h grace so charts/new-releases still refresh periodically even with
        // static taste; manual: 30 min, mainly guarding against repeat "Ververs"
        // taps). A genuine taste change always forces a full run regardless.
        let tasteSig = DiscoveryPipeline.tasteSignature(
            topArtists: topArtists, liked: hints.liked, disliked: hints.disliked,
            watchlist: watchlist.map(\.artist))
        if let last = try? await db.latestBatchInfo(),
           DiscoveryPipeline.shouldSkipRun(trigger: trigger, tasteSig: tasteSig,
                                          lastBatchSig: last.tasteSig, lastBatchCreatedAt: last.createdAt, now: Date()) {
            Log.info("Ontdekkingen (\(trigger)): smaak ongewijzigd sinds recente batch — overgeslagen", category: .roon)
            return last.id
        }

        // Producer context.
        let lastfm: LastfmCredentials? = {
            guard let u = KeychainStore.load(key: "lastfm_username"), !u.isEmpty,
                  let k = KeychainStore.load(key: "lastfm_api_key"), !k.isEmpty else { return nil }
            return LastfmCredentials(apiKey: k, username: u)
        }()
        let listenBrainz: ListenBrainzCredentials? = await {
            guard let token = KeychainStore.load(key: "listenbrainz_token"), !token.isEmpty else { return nil }
            guard let username = await ListenBrainzClient.shared.resolveUsername(token: token) else { return nil }
            return ListenBrainzCredentials(username: username, token: token)
        }()
        let llmConfig = LLMConfigStore.load()
        // Warm a local Ollama model once up front so the AI-picks producer's first
        // call doesn't eat a cold-start timeout (matches buildRadioPlaylists).
        // No-op for cloud providers.
        await LLMClient.shared.warmUp(config: llmConfig)
        let context = ProducerContext(
            lastfm: lastfm, listenBrainz: listenBrainz, musicBrainz: MusicBrainzDiscoveryClient.shared,
            llmConfig: llmConfig, perProducerLimit: 40)

        let qobuz: (email: String, password: String)? = {
            guard let e = KeychainStore.load(key: "qobuz_email"), !e.isEmpty,
                  let p = KeychainStore.load(key: "qobuz_password"), !p.isEmpty else { return nil }
            return (e, p)
        }()

        let filterCtx = DiscoveryFilterContext(
            libraryArtists: libraryArtists, libraryAlbumKeys: libraryAlbumKeys,
            listenedArtists: (try? await db.listenedArtistSet()) ?? [],
            rejections: (try? await db.activeRejections()) ?? [:],
            cooldownDays: discoveryRejectionCooldownDays, scoreThreshold: 0.35, now: Date())

        let rates = await feedbackGenreRates()

        let pipeline = DiscoveryPipeline(producers: activeDiscoveryProducers,
                                         weights: .tuned(adventurousness: discoveryAdventurousness))
        let stored = await pipeline.run(
            seeds: seeds, context: context, qobuzCreds: qobuz,
            libraryGenres: libraryGenres, feedbackGenreRates: rates,
            filterContext: filterCtx, maxItems: Self.discoveryMaxItems, now: Date())

        // Advance each watchlist artist's "newest release seen" watermark, so
        // Release-Radar doesn't keep re-surfacing the same release attempt forever
        // — regardless of whether it actually made it into this batch (filtered
        // out as below-threshold/in-library is still "seen"). Runs after the
        // pipeline so it rides the MusicBrainzDiscoveryClient's warm per-run cache
        // (ReleaseRadarProducer already fetched these same artists/albums).
        await advanceWatchlistWatermarks(seeds.watchlist, musicBrainz: context.musicBrainz, db: db)

        guard !stored.isEmpty else {
            Log.info("Ontdekkingen (\(trigger)): 0 aanbevelingen na resolve/score/filter", category: .roon)
            return nil
        }
        let batchID = try? await db.storeRecommendationBatch(stored, trigger: trigger, tasteSig: tasteSig)
        try? await db.pruneOldBatches(keeping: 3)
        Log.info("Ontdekkingen (\(trigger)): \(stored.count) aanbevelingen opgeslagen (batch \(batchID.map(String.init) ?? "?"))", category: .roon)
        if batchID != nil { await generateExplanations(db: db, llmConfig: llmConfig, count: stored.count) }
        return batchID
    }

    /// Fill in the "waarom past dit"-card for every item of the just-stored batch:
    /// reuse a cached explanation when this exact recommendation (dedup_key) was
    /// already explained under the same signature, otherwise ask the LLM once for
    /// every miss in a single batched call. Never blocks the batch — a fully
    /// failed call just leaves the templated fallback (the feed already treats
    /// `explanation` as optional).
    private func generateExplanations(db: DatabaseManager, llmConfig: LLMConfig, count: Int) async {
        let rows = (try? await db.latestRecommendationItems(limit: count)) ?? []
        guard !rows.isEmpty else { return }

        // Rows needing a fresh explanation, paired with their signature and the
        // 1-based prompt index — cached hits are written immediately and excluded.
        var misses: [(row: DatabaseManager.RecommendationRow, sig: String)] = []
        for row in rows {
            let sourceLabels = row.sources.map { $0.producer }
            let sig = DiscoveryExplanations.signature(artist: row.artist, album: row.album,
                                                      sourceLabels: sourceLabels, genres: row.genres)
            if let cached = try? await db.cachedExplanation(dedupKey: row.dedupKey, sig: sig), !cached.isEmpty {
                try? await db.setRecommendationExplanation(id: row.id, explanation: cached, sig: sig)
            } else {
                misses.append((row, sig))
            }
        }
        guard !misses.isEmpty else { return }

        let promptItems = misses.enumerated().map { i, m in
            DiscoveryExplanations.Item(index: i + 1, artist: m.row.artist, album: m.row.album,
                                       sourceLabels: m.row.sources.map { $0.producer }, genres: m.row.genres)
        }
        let (system, user) = DiscoveryExplanations.buildPrompt(promptItems)
        let parsed: [Int: String]
        if let raw = try? await LLMClient.shared.complete(
            system: system, user: user, config: llmConfig, jsonMode: true, temperature: 0.5, maxTokens: 2048) {
            parsed = DiscoveryExplanations.parseResponse(raw)
        } else {
            parsed = [:]
        }

        for (i, m) in misses.enumerated() {
            let sourceCount = m.row.sources.count
            let text = parsed[i + 1] ?? DiscoveryExplanations.fallback(sourceCount: sourceCount, genres: m.row.genres)
            try? await db.setRecommendationExplanation(id: m.row.id, explanation: text, sig: m.sig)
        }
    }

    /// Set each watchlist artist's `last_seen_rg` to their current newest studio
    /// release, so next run's Release-Radar only emits genuinely new releases.
    /// Best-effort: an artist that fails to resolve keeps its prior watermark.
    private func advanceWatchlistWatermarks(_ watchlist: [WatchlistArtist], musicBrainz: MusicBrainzDiscoveryClient, db: DatabaseManager) async {
        for artist in watchlist {
            let mbid: String?
            if let existing = artist.artistMbid, !existing.isEmpty { mbid = existing }
            else { mbid = await musicBrainz.resolveArtist(name: artist.displayName)?.mbid }
            guard let mbid, let newest = await musicBrainz.studioAlbums(artistMbid: mbid).first else { continue }
            try? await db.updateWatchlistSeenRG(artist: artist.displayName, releaseGroup: newest.mbid)
        }
    }

    // MARK: - Server: accept / play / reject

    @discardableResult
    func serverAcceptRecommendation(_ id: Int64) async -> Bool {
        guard let db = database, let row = try? await db.recommendationRow(id: id) else { return false }
        // 1. Save the album into the stable "Ontdekkingen" Qobuz playlist.
        if row.kind == .album, let qid = row.qobuzAlbumID, !qid.isEmpty,
           let e = KeychainStore.load(key: "qobuz_email"), !e.isEmpty,
           let p = KeychainStore.load(key: "qobuz_password"), !p.isEmpty {
            let ok = await QobuzClient.shared.appendAlbumToPlaylist(
                name: Self.discoveryPlaylistName, description: "Ontdekkingen bewaard door RoonSage.",
                albumID: qid, email: e, password: p)
            if !ok { Log.warning("Ontdekkingen: album '\(row.album ?? "")' niet in Qobuz-playlist opgeslagen", category: .network) }
        }
        // 2. Follow the artist (Release-Radar).
        try? await db.addToWatchlist(artist: row.artist, mbid: row.artistMbid, displayName: row.artist, source: "accept")
        // 3. Mark accepted.
        try? await db.setRecommendationStatus(id: id, status: "accepted")
        return true
    }

    @discardableResult
    func serverPlayRecommendation(_ id: Int64, zoneID: String?) async -> Bool {
        guard let db = database, let row = try? await db.recommendationRow(id: id) else { return false }
        guard let zone = zoneID ?? selectedZone?.id else {
            reportError("Kies eerst een zone om op af te spelen.")
            return false
        }
        var pairs: [(title: String, artist: String?)] = []
        if row.kind == .album, let qid = row.qobuzAlbumID, !qid.isEmpty,
           let e = KeychainStore.load(key: "qobuz_email"), !e.isEmpty,
           let p = KeychainStore.load(key: "qobuz_password"), !p.isEmpty {
            pairs = await QobuzClient.shared.albumTrackTitles(albumID: qid, email: e, password: p)
        }
        // Fallback (artist-kind, or an unresolved album): a single Roon global
        // search on the artist/album name.
        if pairs.isEmpty { pairs = [(title: row.album ?? row.artist, artist: row.artist)] }

        let tracks = pairs.map {
            TrackRecord(id: BrowseService.qobuzSearchKey(artist: $0.artist, title: $0.title),
                        title: $0.title, artist: $0.artist, album: row.album)
        }
        await curateTracks(tracks, zoneID: zone)
        return true
    }

    @discardableResult
    func serverRejectRecommendation(_ id: Int64, permanent: Bool) async -> Bool {
        guard let db = database, let row = try? await db.recommendationRow(id: id) else { return false }
        try? await db.recordRejection(dedupKey: row.dedupKey, kind: row.kind,
                                      artist: row.artist, album: row.album, permanent: permanent)
        let iso = ISO8601DateFormatter().string(from: Date())
        try? await db.setRecommendationStatus(id: id, status: "rejected", rejectedAt: iso)
        return true
    }

    // MARK: - Server: HTTP data helpers (called by LibraryShareServer)

    public func discoveryRecommendationsData(kind: RecommendationKind?, limit: Int) async -> Data {
        let items = await discoveryRecommendations(kind: kind, limit: limit)
        return (try? JSONEncoder().encode(items)) ?? Data("[]".utf8)
    }

    public func discoveryRunStatusData() async -> Data {
        let status = (try? await database?.latestBatchStatus()) ?? DiscoveryRunStatus(status: "idle", itemCount: 0, createdAt: nil)
        return (try? JSONEncoder().encode(status)) ?? Data("{}".utf8)
    }

    public func discoveryStatsData() async -> Data {
        let stats = await localDiscoveryStats()
        return (try? JSONEncoder().encode(stats)) ?? Data("{}".utf8)
    }

    public func handleDiscoveryAction(_ path: String, body: Data) async -> Bool {
        guard let req = try? JSONDecoder().decode(DiscoveryActionRequest.self, from: body) else { return false }
        switch path {
        case let p where p.hasPrefix("/discovery/accept"): return await serverAcceptRecommendation(req.itemID)
        case let p where p.hasPrefix("/discovery/play"):   return await serverPlayRecommendation(req.itemID, zoneID: req.zoneID)
        case let p where p.hasPrefix("/discovery/reject"): return await serverRejectRecommendation(req.itemID, permanent: req.permanent ?? false)
        default: return false
        }
    }

    // MARK: - Client: remote fetch

    private func fetchDiscoveryFromServer(kind: RecommendationKind?, limit: Int) async -> [RecommendationItemDTO] {
        guard let base = remoteBaseURL else { return [] }
        let kindParam = kind?.rawValue ?? "all"
        guard let url = URL(string: "\(base)/discovery/recommendations?kind=\(kindParam)&limit=\(limit)") else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let items = try? JSONDecoder().decode([RecommendationItemDTO].self, from: data) else { return [] }
        return items
    }

    private func fetchDiscoveryStatusFromServer() async -> DiscoveryRunStatus {
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/discovery/run-status") else {
            return DiscoveryRunStatus(status: "idle", itemCount: 0, createdAt: nil)
        }
        var req = URLRequest(url: url); req.timeoutInterval = 10
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let status = try? JSONDecoder().decode(DiscoveryRunStatus.self, from: data) else {
            return DiscoveryRunStatus(status: "idle", itemCount: 0, createdAt: nil)
        }
        return status
    }

    private func fetchDiscoveryStatsFromServer() async -> DiscoveryStatsDTO {
        let empty = DiscoveryStatsDTO(accepted: 0, rejected: 0, pending: 0, approvalRate: 0,
                                      producers: [], topGenres: [], generatedAt: "")
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/discovery/stats") else { return empty }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let stats = try? JSONDecoder().decode(DiscoveryStatsDTO.self, from: data) else { return empty }
        return stats
    }

    @discardableResult
    private func postDiscoveryAction(_ path: String, _ request: DiscoveryActionRequest) async -> Bool {
        guard let base = remoteBaseURL, let url = URL(string: base + path) else {
            reportError("Geen verbinding met de RoonSage-server.")
            return false
        }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(request)
        req.timeoutInterval = 30
        authorizeShareRequest(&req)
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            reportError("Actie mislukt — is de RoonSage-server bereikbaar?")
            return false
        }
        return true
    }

    // MARK: - Per-genre feedback learning (feeds the feedbackBoost score)

    /// Per-genre approve-rate + strong-negative fraction, from `track_feedback`
    /// joined to MB genres. Empty when there's no feedback (→ neutral 0.5 boost).
    func feedbackGenreRates() async -> [String: (approve: Double, strongNeg: Double)] {
        guard let db = database, !feedbackByMatchKey.isEmpty else { return [:] }
        let genresByKey = (try? await db.mbGenresForMatchKeys(Array(feedbackByMatchKey.keys))) ?? [:]
        var like: [String: Int] = [:], dislike: [String: Int] = [:]
        for (mk, kind) in feedbackByMatchKey {
            guard let gs = genresByKey[mk] else { continue }
            for g in gs {
                let lg = g.lowercased()
                if kind == .like { like[lg, default: 0] += 1 } else { dislike[lg, default: 0] += 1 }
            }
        }
        var rates: [String: (approve: Double, strongNeg: Double)] = [:]
        for g in Set(like.keys).union(dislike.keys) {
            let l = Double(like[g] ?? 0), d = Double(dislike[g] ?? 0)
            let total = l + d
            guard total > 0 else { continue }
            rates[g] = (approve: l / total, strongNeg: d / total)
        }
        return rates
    }

    // MARK: - Auto-refresh (server build)

    /// Start the daily discovery run. No-op unless this is the always-on server
    /// build (`.direct`); client apps trigger runs on demand from the UI.
    public func startDiscoveryRefresh() {
        guard controlMode == .direct, discoveryRefreshTask == nil else { return }
        discoveryRefreshTask = Task { [weak self] in
            // Grace so the library + features are ready before the first run.
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                let batch = await self.runDiscoveryPipeline(trigger: "scheduled")
                // Re-run daily once it produced something; retry sooner while warming up.
                let wait = batch != nil ? Self.discoveryRefreshInterval : 30 * 60 * 1_000_000_000
                try? await Task.sleep(nanoseconds: wait)
            }
        }
        Log.info("Ontdekkingen auto-run gestart (eerste poging na 60s, daarna dagelijks)", category: .roon)
    }

    public func stopDiscoveryRefresh() {
        discoveryRefreshTask?.cancel()
        discoveryRefreshTask = nil
    }
}
