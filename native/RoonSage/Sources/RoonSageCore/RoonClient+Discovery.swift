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
    /// Batches kept after pruning (F12b: the weekly digest draws from every
    /// retained batch, so this must span at least a week of daily runs).
    nonisolated static let discoveryBatchRetention = 14
    /// How often the digest scheduler checks whether today is digest day.
    nonisolated static let discoveryDigestCheckInterval: UInt64 = 60 * 60 * 1_000_000_000
    /// Albums kept in the weekly digest playlist.
    nonisolated static let discoveryDigestSize = 20
    /// Hourly digest tries per ISO week before giving up (watermark → 0), so a
    /// persistently failing Qobuz save doesn't retry — and log — every hour forever.
    nonisolated static let discoveryDigestMaxAttempts = 3

    /// The producers that run each pipeline pass. Ships every Last.fm/MusicBrainz/
    /// ListenBrainz/AI producer; the gated Deezer/Spotify/Discogs producers (each
    /// needs a new client + the user's own account) land later. Public so the
    /// analyzer's tuning settings can list `id`s for the enable/disable toggles
    /// without hand-duplicating them.
    public static var discoveryProducers: [DiscoveryProducer] {
        [SimilarArtistWebProducer(), ChartsProducer(), ReleaseRadarProducer(),
         GapFillProducer(), ArtistRelationshipsProducer(), ListenBrainzRadioProducer(), AIPicksProducer(),
         DiscogsLabelsProducer(), QobuzCatalogProducer(), DatasetProducer()]
    }

    /// Whether a Discogs personal access token is configured (Settings → Externe
    /// diensten). Gates `DiscogsLabelsProducer` — the producer's own `isEnabled`
    /// checks the same thing via `ProducerContext.discogsToken`, so a missing
    /// token degrades to "one fewer producer", same as every other optional source.
    public var discogsConfigured: Bool {
        !(KeychainStore.load(key: "discogs_token") ?? "").isEmpty
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

    /// Path to the distilled MusicMoveArr dataset sidecar (metadata.db) on the
    /// server host — gates `DatasetProducer`. Empty (default) = producer off,
    /// same degradation as a missing Discogs token. Server-side setting, like
    /// the other discovery tuning knobs.
    public var datasetSidecarPath: String {
        get { UserDefaults.standard.string(forKey: "dataset_sidecar_path") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "dataset_sidecar_path") }
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

    // MARK: - Weekly digest (F12b)

    /// Which weekday builds the digest playlist (`Calendar` weekday numbering:
    /// 1 = Sunday … 7 = Saturday, Gregorian). Default 2 (Monday).
    public var discoveryDigestWeekday: Int {
        get { (UserDefaults.standard.object(forKey: "discovery_digest_weekday") as? Int) ?? 2 }
        set { UserDefaults.standard.set(min(7, max(1, newValue)), forKey: "discovery_digest_weekday") }
    }

    /// The most recently built digest (nil until the first one runs). Single
    /// JSON-encoded value rather than four scalar keys — one source of truth for
    /// both the server's own bookkeeping and the `/discovery/digest-status` wire
    /// format (same struct, no separate DTO).
    public var discoveryLastDigest: DiscoveryDigestStatus? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "discovery_last_digest") else { return nil }
            return try? JSONDecoder().decode(DiscoveryDigestStatus.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                UserDefaults.standard.removeObject(forKey: "discovery_last_digest")
                return
            }
            UserDefaults.standard.set(data, forKey: "discovery_last_digest")
        }
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

    /// POST body for `/discovery/run` (F12a: optional mood seed).
    public struct DiscoveryRunRequest: Codable, Sendable {
        public var trigger: String
        public var mood: String?
        public init(trigger: String = "manual", mood: String? = nil) {
            self.trigger = trigger; self.mood = mood
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
    /// `mood` (F12a): a raw CLAP mood key (`RoonClient.knownMoodKeys`) that biases
    /// the seed toward artists whose owned tracks best fit that vibe — "iets als X
    /// maar donkerder". Nil runs exactly as before.
    public func triggerDiscoveryRun(mood: String? = nil) async {
        if isRemote {
            guard let base = remoteBaseURL, let url = URL(string: "\(base)/discovery/run") else { return }
            var req = URLRequest(url: url); req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONEncoder().encode(DiscoveryRunRequest(trigger: "manual", mood: mood))
            req.timeoutInterval = 15
            authorizeShareRequest(&req)
            _ = try? await URLSession.shared.data(for: req)
            return
        }
        runDiscoveryNow(mood: mood)
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
    public func runDiscoveryNow(mood: String? = nil) {
        guard controlMode == .direct else { return }
        Task { [weak self] in _ = await self?.runDiscoveryPipeline(trigger: "manual", mood: mood) }
    }

    /// Assemble the pipeline inputs from the DB + Keychain + feedback, run it, and
    /// store the batch. Returns the new batch id (or nil on skip/failure). `mood`
    /// (F12a) biases the seed toward artists whose owned tracks best fit that vibe;
    /// nil runs exactly as before F12a.
    @discardableResult
    func runDiscoveryPipeline(trigger: String, mood: String? = nil) async -> Int64? {
        guard controlMode == .direct, !discoveryRunning, let db = database else { return nil }
        discoveryRunning = true
        defer { discoveryRunning = false }

        await ensureFeedbackLoaded()

        // Seeds (taste profile).
        let playCounts = (try? await db.topArtistsListened(limit: 60)) ?? []
        var topArtists = playCounts.map { $0.artist }
        let hints = await feedbackArtistHints()
        let libraryArtists = (try? await db.libraryArtistSet()) ?? []
        let libraryGenres = (try? await db.libraryGenreSet()) ?? []
        let genreVocabulary = (try? await db.genreVocabularySet()) ?? []
        let libraryAlbumKeys = (try? await db.libraryAlbumKeySet()) ?? []
        let watchlist = (try? await db.watchlistArtists()) ?? []

        // F2: re-rank the seed artists by CLAP taste representativeness (the artists
        // most central to your sonic core, not just your play-count leaders), so every
        // outward producer expands from your taste rather than raw play counts. Also
        // carries the taste vector into `DiscoverySeeds` for producers that can use it.
        // Requires embeddings; falls back to the play-count order when absent.
        var tasteVector: [Float]?
        if let index = await activeIndex(db) {
            let lib = await radioLibrary()
            tasteVector = await personalTasteVector(lib: lib, index: index)
            if let tv = tasteVector, !lib.isEmpty {
                let playByArtist = Dictionary(playCounts.map { ($0.artist.lowercased(), $0.count) },
                                              uniquingKeysWith: { a, _ in a })
                // Diversify the seed set: ~20% comes from the taste PERIPHERY (rotating
                // per day) rather than the core, so the outward producers don't all
                // expand from the same central neighbourhood — the root cause of every
                // Ontdek surface showing near-identical picks. A mood-seeded run keeps
                // the full core (the mood is already the diversifier there).
                let rotationSalt = mood == nil ? String(ISO8601DateFormatter().string(from: Date()).prefix(10)) : ""
                let ranked = TasteSeeds.diversifiedSeeds(
                    library: lib, tasteVector: tv, playCountByArtist: playByArtist,
                    limit: 60, exploreCount: mood == nil ? 12 : 0, salt: rotationSalt)
                if !ranked.isEmpty {
                    var merged = ranked
                    let seen = Set(ranked.map { $0.lowercased() })
                    for a in topArtists where !seen.contains(a.lowercased()) { merged.append(a) }
                    topArtists = merged
                }
            }
        }

        // F12a: replace the top-played seed with artists whose OWNED tracks best
        // fit the requested mood, so every producer traverses from a mood-
        // appropriate starting point. Falls back to the unbiased seed above when
        // the library has no presence for this mood (never a hard failure) — the
        // AI producer still leans into the vibe via `context.mood` regardless.
        if let mood {
            let tracks = await sonicCache.allTracks(from: db)
            let facts = tracks.map { MoodSeeding.TrackMoodFacts(artist: $0.artist, moods: $0.moods) }
            let moodArtists = MoodSeeding.topArtists(facts, mood: mood, limit: 25)
            if !moodArtists.isEmpty { topArtists = moodArtists }
        }

        let seeds = DiscoverySeeds(
            topArtists: topArtists, likedArtists: hints.liked, dislikedArtists: hints.disliked,
            libraryArtists: libraryArtists, libraryGenres: libraryGenres, libraryAlbumKeys: libraryAlbumKeys,
            watchlist: watchlist, tasteVector: tasteVector)

        guard !topArtists.isEmpty || !hints.liked.isEmpty || !watchlist.isEmpty else {
            Log.info("Ontdekkingen: nog geen luistergeschiedenis/feedback om op te seeden — overgeslagen", category: .roon)
            return nil
        }

        // Skip-if-unchanged guard: don't re-run the whole MB/LLM-costed pipeline
        // when nothing that could change the output has shifted since the last
        // batch and that batch is still fresh enough for this trigger (scheduled:
        // 6h grace so charts/new-releases still refresh periodically even with
        // static taste; manual: 30 min, mainly guarding against repeat "Ververs"
        // taps). A genuine taste change always forces a full run regardless. A
        // mood-seeded run (F12a) always bypasses this — it's a deliberate, one-off
        // request for a specific vibe, never a redundant repeat tap.
        let tasteSig = DiscoveryPipeline.tasteSignature(
            topArtists: topArtists, liked: hints.liked, disliked: hints.disliked,
            watchlist: watchlist.map(\.artist))
        if mood == nil, let last = try? await db.latestBatchInfo(),
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
        let discogsToken = KeychainStore.load(key: "discogs_token").flatMap { $0.isEmpty ? nil : $0 }
        let llmConfig = LLMConfigStore.load()
        // Warm a local Ollama model once up front so the AI-picks producer's first
        // call doesn't eat a cold-start timeout (matches buildRadioPlaylists).
        // No-op for cloud providers.
        await LLMClient.shared.warmUp(config: llmConfig)
        await DiscogsClient.shared.resetCache()

        let qobuz: (email: String, password: String)? = {
            guard let e = KeychainStore.load(key: "qobuz_email"), !e.isEmpty,
                  let p = KeychainStore.load(key: "qobuz_password"), !p.isEmpty else { return nil }
            return (e, p)
        }()

        let sidecarPath = datasetSidecarPath
        let context = ProducerContext(
            lastfm: lastfm, listenBrainz: listenBrainz, musicBrainz: MusicBrainzDiscoveryClient.shared,
            llmConfig: llmConfig, perProducerLimit: 40, mood: mood, discogsToken: discogsToken,
            qobuz: qobuz.map { QobuzCredentials(email: $0.email, password: $0.password) },
            datasetSidecarPath: sidecarPath.isEmpty ? nil : sidecarPath)

        let filterCtx = DiscoveryFilterContext(
            libraryArtists: libraryArtists, libraryAlbumKeys: libraryAlbumKeys,
            listenedArtists: (try? await db.listenedArtistSet()) ?? [],
            rejections: (try? await db.activeRejections()) ?? [:],
            cooldownDays: discoveryRejectionCooldownDays, scoreThreshold: 0.35, now: Date())

        let rates = await feedbackGenreRates()

        // C3: per-producer accept-rate (the same signal the "Ontdek-inzichten"
        // dashboard shows) so the scorer can lightly favour producers you keep and
        // trim ones you keep skipping. Empty on day one → no effect.
        let producerReliability: [String: Double] = await {
            guard let inp = try? await db.discoveryStatsInputs() else { return [:] }
            let stats = DiscoveryStatsBuilder.build(
                items: inp.facts, lifetimeAccepted: inp.accepted, lifetimeRejected: inp.rejected,
                latestPending: inp.latestPending, generatedAt: "")
            return stats.producers.reduce(into: [String: Double]()) { acc, p in
                if let r = p.acceptRate { acc[p.producer] = r }
            }
        }()

        let pipeline = DiscoveryPipeline(producers: activeDiscoveryProducers,
                                         weights: .tuned(adventurousness: discoveryAdventurousness))
        let stored = await pipeline.run(
            seeds: seeds, context: context, qobuzCreds: qobuz,
            libraryGenres: libraryGenres, genreVocabulary: genreVocabulary, feedbackGenreRates: rates,
            producerReliability: producerReliability, adventurousness: discoveryAdventurousness,
            filterContext: filterCtx, maxItems: Self.discoveryMaxItems, now: Date())

        // Advance each watchlist artist's "newest release seen" watermark, so
        // Release-Radar doesn't keep re-surfacing the same release attempt forever
        // — regardless of whether it actually made it into this batch (filtered
        // out as below-threshold/in-library is still "seen"). Runs after the
        // pipeline so it rides the MusicBrainzDiscoveryClient's warm per-run cache
        // (ReleaseRadarProducer already fetched these same artists/albums).
        await advanceWatchlistWatermarks(seeds.watchlist, musicBrainz: context.musicBrainz, db: db)

        // Encode the mood into the stored trigger (existing TEXT column, no schema
        // change) so a mood batch is identifiable in the DB/logs — "mood:sad" etc.
        let effectiveTrigger = mood.map { "mood:\($0)" } ?? trigger

        guard !stored.isEmpty else {
            Log.info("Ontdekkingen (\(effectiveTrigger)): 0 aanbevelingen na resolve/score/filter", category: .roon)
            return nil
        }
        let batchID = try? await db.storeRecommendationBatch(stored, trigger: effectiveTrigger, tasteSig: tasteSig)
        // Kept at 14 (not 3) so the weekly digest (F12b) — which draws from every
        // RETAINED batch, not just the newest — has a full week of daily runs to
        // pick highlights from even right before its own scheduled day.
        try? await db.pruneOldBatches(keeping: Self.discoveryBatchRetention)
        Log.info("Ontdekkingen (\(effectiveTrigger)): \(stored.count) aanbevelingen opgeslagen (batch \(batchID.map(String.init) ?? "?"))", category: .roon)
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

    /// A discovery fetch that failed for a reason worth telling the user about —
    /// so the feed can show "server onbereikbaar · opnieuw proberen" instead of a
    /// silent, misleading "nog geen ontdekkingen". Dutch `errorDescription` feeds
    /// straight into the views' error state.
    public enum DiscoveryFetchError: LocalizedError {
        case notConnected
        case server(Int)
        case transport(String)
        case decode

        public var errorDescription: String? {
            switch self {
            case .notConnected:
                "Geen verbinding met de RoonSage-server. Controleer bij Instellingen → Server of de server bereikbaar is."
            case .server(let code):
                "De server antwoordde met een fout (\(code)). Probeer het zo opnieuw."
            case .transport(let msg):
                "Kon de server niet bereiken: \(msg)"
            case .decode:
                "Het antwoord van de server kon niet worden gelezen."
            }
        }
    }

    /// Shared authenticated GET that *throws* on failure (unlike `try?`-swallowing
    /// fetches), so callers can distinguish an empty result from an unreachable
    /// server. `null` bodies decode fine into optional `T`.
    func shareGETChecked<T: Decodable>(_ path: String, timeout: TimeInterval = 15, as type: T.Type) async throws -> T {
        guard let base = remoteBaseURL, let url = URL(string: base + path) else {
            throw DiscoveryFetchError.notConnected
        }
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        authorizeShareRequest(&req)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw DiscoveryFetchError.transport(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw DiscoveryFetchError.decode }
        guard http.statusCode == 200 else { throw DiscoveryFetchError.server(http.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw DiscoveryFetchError.decode }
    }

    /// The recommendation feed, but surfacing fetch failures (for the feed view's
    /// error state). Server/local path behaves like `discoveryRecommendations`.
    public func discoveryRecommendationsChecked(kind: RecommendationKind? = nil, limit: Int = 60) async throws -> [RecommendationItemDTO] {
        if isRemote {
            let kindParam = kind?.rawValue ?? "all"
            return try await shareGETChecked("/discovery/recommendations?kind=\(kindParam)&limit=\(limit)",
                                             as: [RecommendationItemDTO].self)
        }
        guard let db = database else { return [] }
        let rows = (try? await db.latestRecommendationItems(kind: kind, limit: limit)) ?? []
        return rows.map { $0.dto }
    }

    /// Stats, surfacing fetch failures (for the insights view's error state).
    public func discoveryStatsChecked() async throws -> DiscoveryStatsDTO {
        if isRemote { return try await shareGETChecked("/discovery/stats", timeout: 12, as: DiscoveryStatsDTO.self) }
        return await localDiscoveryStats()
    }

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

    // MARK: - Weekly digest scheduler (F12b, server build)

    /// Hourly-checked weekday watch for the digest. Hourly (not daily-exact) so a
    /// server that was asleep/offline right at midnight still catches "today is
    /// the day" within the hour, same posture as the discovery refresh's own
    /// startup grace.
    public func startDigestSchedule() {
        guard controlMode == .direct, digestScheduleTask == nil else { return }
        digestScheduleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)   // let the library settle first
            while !Task.isCancelled {
                guard let self else { return }
                await self.buildWeeklyDigestIfDue()
                try? await Task.sleep(nanoseconds: Self.discoveryDigestCheckInterval)
            }
        }
        Log.info("Ontdekkingen-digest scheduler gestart (elk uur gecontroleerd)", category: .roon)
    }

    public func stopDigestSchedule() {
        digestScheduleTask?.cancel()
        digestScheduleTask = nil
    }

    /// Builds this week's digest playlist if today is the configured weekday AND
    /// this ISO week hasn't been built yet. The strongest still-pending album
    /// recommendations across every retained batch (`DigestSelection.top`) are
    /// saved into a dated Qobuz playlist ("Ontdekkingen — 2026-W27"); `appendAlbumToPlaylist`
    /// finds-or-creates by exact name, so repeat calls within the same week are
    /// additive/idempotent-safe rather than duplicating a playlist. On any skip
    /// path the watermark is left untouched so the next hourly check retries —
    /// only a successful (or genuinely empty) build advances it.
    func buildWeeklyDigestIfDue(now: Date = Date()) async {
        guard controlMode == .direct, let db = database else { return }
        guard Calendar.current.component(.weekday, from: now) == discoveryDigestWeekday else { return }
        let weekKey = DigestSelection.weekKey(for: now)
        guard discoveryLastDigest?.week != weekKey else { return }   // already built this week

        let candidates = (try? await db.recentPendingAlbumRecommendations()) ?? []
        let top = DigestSelection.top(candidates, limit: Self.discoveryDigestSize)
        let builtAt = ISO8601DateFormatter().string(from: now)

        guard !top.isEmpty else {
            discoveryLastDigest = DiscoveryDigestStatus(week: weekKey, count: 0, playlistName: nil, builtAt: builtAt)
            Log.info("Ontdekkingen-digest (\(weekKey)): geen wachtende albums om te bundelen", category: .roon)
            return
        }
        guard let email = KeychainStore.load(key: "qobuz_email"), !email.isEmpty,
              let password = KeychainStore.load(key: "qobuz_password"), !password.isEmpty else {
            Log.info("Ontdekkingen-digest (\(weekKey)): Qobuz niet ingesteld — overgeslagen (watermark niet gezet, volgende controle probeert opnieuw)", category: .roon)
            return
        }

        let playlistName = "Ontdekkingen — \(weekKey)"
        var saved = 0
        for candidate in top {
            guard let qid = candidate.qobuzAlbumID, !qid.isEmpty else { continue }
            let ok = await QobuzClient.shared.appendAlbumToPlaylist(
                name: playlistName, description: "Wekelijkse Ontdekkingen-selectie van RoonSage.",
                albumID: qid, email: email, password: password)
            if ok { saved += 1 }
        }
        guard saved > 0 else {
            let attempt = bumpDigestFailure(weekKey)
            if attempt >= Self.discoveryDigestMaxAttempts {
                // Give up for this week so the hourly check stops retrying (and stops
                // spamming the log). A count-0 watermark advances past this week; the
                // week key changes next week, which re-arms the digest.
                discoveryLastDigest = DiscoveryDigestStatus(week: weekKey, count: 0, playlistName: nil, builtAt: builtAt)
                Log.warning("Ontdekkingen-digest (\(weekKey)): Qobuz-opslag \(attempt)× mislukt voor alle \(top.count) albums — opgegeven voor deze week (volgende week opnieuw)", category: .network)
            } else {
                Log.warning("Ontdekkingen-digest (\(weekKey)): Qobuz-opslag mislukte voor alle \(top.count) albums (poging \(attempt)/\(Self.discoveryDigestMaxAttempts)) — watermark niet gezet", category: .network)
            }
            return
        }
        discoveryLastDigest = DiscoveryDigestStatus(week: weekKey, count: saved, playlistName: playlistName, builtAt: builtAt)
        Log.info("Ontdekkingen-digest (\(weekKey)): \(saved) albums opgeslagen naar '\(playlistName)'", category: .roon)
    }

    /// Count this week's consecutive digest failures (persisted, so a restart
    /// doesn't reset the back-off and re-spam). Resets when the ISO week changes.
    private func bumpDigestFailure(_ weekKey: String) -> Int {
        let d = UserDefaults.standard
        if d.string(forKey: "discovery_digest_fail_week") != weekKey {
            d.set(weekKey, forKey: "discovery_digest_fail_week")
            d.set(0, forKey: "discovery_digest_fail_count")
        }
        let n = d.integer(forKey: "discovery_digest_fail_count") + 1
        d.set(n, forKey: "discovery_digest_fail_count")
        return n
    }

    // MARK: - Digest status (client + server)

    /// The most recent digest. Server reads its own bookkeeping; clients pull
    /// `/discovery/digest-status`.
    public func discoveryDigestStatus() async -> DiscoveryDigestStatus {
        if isRemote { return await fetchDigestStatusFromServer() }
        return discoveryLastDigest ?? DiscoveryDigestStatus(week: nil, count: 0, playlistName: nil, builtAt: nil)
    }

    public func discoveryDigestStatusData() async -> Data {
        let status = discoveryLastDigest ?? DiscoveryDigestStatus(week: nil, count: 0, playlistName: nil, builtAt: nil)
        return (try? JSONEncoder().encode(status)) ?? Data("{}".utf8)
    }

    private func fetchDigestStatusFromServer() async -> DiscoveryDigestStatus {
        let empty = DiscoveryDigestStatus(week: nil, count: 0, playlistName: nil, builtAt: nil)
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/discovery/digest-status") else { return empty }
        var req = URLRequest(url: url); req.timeoutInterval = 10
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let status = try? JSONDecoder().decode(DiscoveryDigestStatus.self, from: data) else { return empty }
        return status
    }
}
