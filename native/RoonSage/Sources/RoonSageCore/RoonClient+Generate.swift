import Foundation

// MARK: - AI playlist generation (Core)

/// The full "analyse → candidates → curate → name" playlist pipeline, lifted out
/// of the view so it's testable, reusable (Ask / MCP), and shared with the
/// unified request analyzer. The view now only owns prompt + presentation state.
extension RoonClient {

    /// A finished AI generation: the curated tracks plus everything the UI needs
    /// to present it honestly (the scope that actually survived broadening, an
    /// AI title/description, and whether the LLM really curated it vs a top-up
    /// fallback when the model under-delivered).
    public struct GenerationResult: Sendable, Codable {
        public var tracks: [TrackRecord]
        public var filters: RequestFilters     // the scope that survived broadening
        public var poolSize: Int
        public var title: String
        public var description: String?
        public var droppedNote: String?        // genre intent couldn't be honoured
        public var aiCurated: Bool             // false = top-up only (LLM under-delivered)
        /// Set when the sonic ranking wasn't available and the candidate pool was
        /// shuffled instead — shown by the UI so a random-ish pick is never
        /// presented as a sonic one. Optional + defaulted: wire-compatible with
        /// older servers that don't send it.
        public var fallbackNote: String? = nil
        /// Per-track "waarom deze track" (RadioEngine.Reason, NL), keyed by
        /// TrackRecord.id. Empty when the engine path wasn't available.
        public var reasonByTrackID: [String: String] = [:]
        /// A full diagnostic trace of how this playlist was built (also logged,
        /// category `.llm`). Shown in the app's "Diagnostiek" panel.
        public var trace: String? = nil
    }

    /// Stages reported back to the UI so it can show a staged progress indicator
    /// instead of one opaque spinner.
    public enum GenerationPhase: Int, CaseIterable, Sendable {
        case analyzing, candidates, curating, naming

        public var label: String {
            switch self {
            case .analyzing:  "Analyseren"
            case .candidates: "Kandidaten"
            case .curating:   "Cureren"
            case .naming:     "Titel"
            }
        }
    }

    public enum GenerationError: LocalizedError {
        case noCandidates
        case emptyResult

        public var errorDescription: String? {
            switch self {
            case .noCandidates:
                "Geen passende tracks — synchroniseer je bibliotheek of probeer een bredere omschrijving."
            case .emptyResult:
                "Kon geen playlist samenstellen — probeer een bredere omschrijving."
            }
        }
    }

    /// Wire request for server-side generation (`POST /generate`). The client
    /// sends the user's raw parameters; the server runs the full local pipeline.
    public struct GenerateRequestDTO: Codable, Sendable {
        public var request: String
        public var target: Int
        public var adventurousness: Double
        public var arc: String?            // RadioSequencer.Arc wire key, nil = auto
        public var targetMinutes: Int?
        public var seedArtists: [String]
        public var seedTrackKeys: [String]
        public init(request: String, target: Int, adventurousness: Double, arc: String?,
                    targetMinutes: Int?, seedArtists: [String], seedTrackKeys: [String]) {
            self.request = request; self.target = target; self.adventurousness = adventurousness
            self.arc = arc; self.targetMinutes = targetMinutes
            self.seedArtists = seedArtists; self.seedTrackKeys = seedTrackKeys
        }
    }

    /// A generation that failed on the server — carries the server's (Dutch)
    /// error message so the UI shows the same copy as a local failure would.
    public struct RemoteGenerationError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Taste signals folded into curation: artists the listener favours / likes /
    /// dislikes, and identities recently generated (anti-repetition).
    public struct TasteContext: Sendable {
        public var preferred: Set<String>      // lowercased top-played artists
        public var liked: [String]
        public var disliked: [String]
        public var deprioritized: Set<String>  // recent generation identities
    }

    /// Generate a curated playlist for a free-text request. Throws `LLMError`
    /// (status-aware, Dutch) when the curation model is unreachable, or
    /// `GenerationError` when the library can't supply candidates.
    ///
    /// `adventurousness` mirrors the radio dial (0 = vertrouwd, 1 = ontdekkend);
    /// `arc` is the energy shape the final set is flow-ordered into — nil derives
    /// it from the request (M3: "workout" peaks, "focus/chill" stays smooth).
    /// `targetMinutes` (U3), when set, overrides `target`: the pipeline curates a
    /// generous over-estimate of tracks, flow-orders them, then trims the set to
    /// the requested play-time using measured per-track durations.
    public func generatePlaylist(
        request: String, target: Int,
        adventurousness: Double = RoonClient.defaultAdventurousness,
        arc: RadioSequencer.Arc? = nil,
        targetMinutes: Int? = nil,
        seedArtists: [String] = [],
        seedTrackKeys: [String] = [],
        onProgress: ((GenerationPhase) -> Void)? = nil
    ) async throws -> GenerationResult {
        // Thin clients run generation on the server-of-record (the mini): it has
        // the authoritative library + feedback and a local LLM, and — the reason
        // this exists — it logs the full trace centrally. Falls back to the local
        // pipeline below when the server is too old to know /generate (404).
        if isRemote {
            onProgress?(.analyzing)
            let dto = GenerateRequestDTO(
                request: request, target: target, adventurousness: adventurousness,
                arc: arc.map(Self.arcWireKey), targetMinutes: targetMinutes,
                seedArtists: seedArtists, seedTrackKeys: seedTrackKeys)
            if let result = try await remoteGeneratePlaylist(dto) { return result }
            // else: server has no /generate → fall through to local generation.
        }
        let config = effectiveLLMConfig()
        // A duration target curates extra tracks so the post-trim set still hits
        // the minute budget (avg track ≈ 3.5 min, +4 slack); trimming happens
        // after flow-ordering so the journey — not just the count — is preserved.
        let target = targetMinutes.map { min(100, max(5, Int(ceil(Double($0) / 3.5)) + 4)) } ?? target

        // Diagnostic trace of the whole run (logged + returned). Purely for
        // inspection — never read back into the pipeline.
        let trace = GenerationTrace()
        trace.section("Verzoek")
        trace.kv("prompt", "“\(request)”")
        trace.kv("doel", targetMinutes.map { "\($0) min (≈\(target) tracks)" } ?? "\(target) tracks")
        trace.kv("avontuurlijkheid", String(format: "%.2f", adventurousness))
        trace.kv("verloop", arc.map(Self.arcLabel) ?? "auto")
        trace.kvIf("seed-artiesten", GenerationTrace.list(seedArtists))
        trace.kvIf("seed-nummers", "\(seedTrackKeys.count)")
        trace.kv("LLM", "\(config.provider.rawValue)/\(config.effectiveModel)")

        // Stage 1 — analyse the request into library filters (genres/tags/decades
        // + measured moods/activities).
        try Task.checkCancellation()
        onProgress?(.analyzing)
        let analysis = await analyzeForFilters(request: request)
        trace.section("1 · Analyse → filters")
        trace.kv("genres", GenerationTrace.list(analysis.genres))
        trace.kv("tags", GenerationTrace.list(analysis.tags))
        trace.kv("sferen", GenerationTrace.list(analysis.moods.map { Self.moodLabel($0) }))
        trace.kv("activiteiten", GenerationTrace.list(analysis.activities.map { Self.activityLabel($0) }))
        trace.kv("decennia", GenerationTrace.list(analysis.decades.sorted().map { "\($0)s" }))
        trace.kvIf("trefwoorden", analysis.keywords)

        // Shared sonic context for the whole pipeline: the analyzed library keyed
        // by content, plus the library calibration that makes mood/energy
        // judgements library-relative. Engine ranking, curator hints, the flow
        // sequencer and the grounded title all read from this one snapshot.
        let lib = await radioLibrary()
        let sonicByKey = Dictionary(lib.filter { !$0.matchKey.isEmpty }.map { ($0.matchKey, $0) },
                                    uniquingKeysWith: { a, _ in a })
        let calibration: TitleGrounding.Calibration? = lib.isEmpty ? nil
            : await Task.detached { TitleGrounding.Calibration.compute(library: lib) }.value

        // U2 — resolve user-picked seed artists/tracks into real embedding anchors
        // (like a station's seeds) and their Deezer fan-graph. `queryAnchor` (the
        // request phrase) still joins them, so a seeded generation is "sounds like
        // these AND like the request". Cap per artist so a prolific one can't
        // dominate the centroid.
        let (seeds, relatedArtists) = await resolveGenerationSeeds(
            artists: seedArtists, trackKeys: seedTrackKeys, sonicByKey: sonicByKey, lib: lib)
        if !seedArtists.isEmpty || !seedTrackKeys.isEmpty {
            trace.section("2 · Seeds")
            trace.kv("opgeloste seed-tracks", "\(seeds.count)")
            trace.kv("voorbeelden", GenerationTrace.list(seeds.prefix(8).map {
                "\($0.title) — \($0.artist ?? "?")" }))
            trace.kv("fan-graph-artiesten (Deezer)", "\(relatedArtists.count)")
        }

        // Stage 2 — build a sonically-ranked candidate pool (broadened as needed).
        try Task.checkCancellation()
        onProgress?(.candidates)
        let built = await buildCandidatePool(request: request, filters: analysis, target: target,
                                             adventurousness: adventurousness,
                                             sonicByKey: sonicByKey, calibration: calibration,
                                             seeds: seeds, relatedArtists: relatedArtists, trace: trace)
        guard !built.pool.isEmpty else { throw GenerationError.noCandidates }
        let candidates = built.pool
        let survived = built.survived

        // Warn when a genre/mood was asked for but the library couldn't honour it.
        let wantedScope = !analysis.genres.isEmpty || !analysis.tags.isEmpty
            || !analysis.moods.isEmpty || !analysis.activities.isEmpty
        let lostScope = survived.genres.isEmpty && survived.tags.isEmpty
            && survived.moods.isEmpty && survived.activities.isEmpty
        let droppedNote = (wantedScope && lostScope)
            ? "Te weinig tracks voor dit genre in je bibliotheek — gekozen uit de hele bibliotheek."
            : nil

        // Stage 3 — LLM curation + deterministic assembly + flow-sequencing.
        try Task.checkCancellation()
        onProgress?(.curating)
        let taste = await tasteContext(pool: candidates)
        trace.section("4 · Curatie (LLM)")
        trace.kv("smaak-hints", "likes \(taste.liked.count) · dislikes \(taste.disliked.count) · voorkeur-artiesten \(taste.preferred.count)")
        let curated = try await curate(request: request, target: target,
                                       candidates: candidates, taste: taste,
                                       sonic: sonicByKey, config: config, trace: trace)
        guard !curated.tracks.isEmpty else { throw GenerationError.emptyResult }
        // QW1 — order the set into a designed journey (CLAP/BPM/key/energy-arc)
        // instead of leaving it in LLM pick order.
        let picks = curated.tracks
        // M3 — derive the energy arc from the request when the caller left it to
        // "Auto" (nil), so a workout set peaks and a focus set glides.
        let effectiveArc = arc ?? Self.suggestedArc(for: analysis)
        var ordered = await Task.detached { Self.flowOrder(picks, byKey: sonicByKey, arc: effectiveArc) }.value
        trace.section("5 · Volgorde & duur")
        trace.kv("verloop", "\(Self.arcLabel(effectiveArc))\(arc == nil ? " (auto)" : "")")

        // U3 — trim the flow-ordered set to the requested play-time. Durations
        // come from the analysed features; unanalysed tracks fall back to the
        // 3.5-min average so an un-timed track still advances the budget.
        if let targetMinutes {
            let keys = ordered.compactMap(\.matchKey)
            let durations = await (database?.durationByMatchKey(keys) ?? [:])
            let before = ordered.count
            ordered = Self.trimToDuration(ordered, budgetSeconds: Double(targetMinutes) * 60,
                                          durationByKey: durations)
            let mins = ordered.reduce(0.0) { $0 + ($1.matchKey.flatMap { durations[$0] } ?? 210) } / 60
            trace.kv("duur-trim", "\(before) → \(ordered.count) tracks (≈\(Int(mins.rounded())) min, doel \(targetMinutes))")
        }

        // Stage 4 — grounded AI title + description (Dutch).
        try Task.checkCancellation()
        onProgress?(.naming)
        let meta = await describePlaylist(request: request, tracks: ordered,
                                          sonic: sonicByKey, calibration: calibration,
                                          config: config, trace: trace)

        // Result summary: the final tracklist + why each is here.
        trace.section("Resultaat")
        trace.kv("titel", "“\(meta.title)”")
        trace.kv("tracks", "\(ordered.count) · uit pool van \(candidates.count) · \(curated.aiCurated ? "AI-gecureerd" : "aangevuld (LLM onder-leverde)")")
        for (i, t) in ordered.prefix(60).enumerated() {
            let reason = built.reasons[t.id].map { " — \($0)" } ?? ""
            trace.line(String(format: "%2d. %@ — %@%@", i + 1, t.title, t.artist ?? "?", reason))
        }
        let rendered = trace.render()
        Log.info("\n\(rendered)", category: .llm)

        // Only record into the anti-repetition trail once the result is final and
        // not cancelled — a stopped generation the user never saw shouldn't bias
        // the next one.
        try Task.checkCancellation()
        rememberGenerated(ordered)
        return GenerationResult(
            tracks: ordered, filters: survived, poolSize: candidates.count,
            title: meta.title, description: meta.description,
            droppedNote: droppedNote, aiCurated: curated.aiCurated,
            fallbackNote: built.sonicRanked ? nil
                : "Sonische rangschikking niet beschikbaar — de selectie is minder klank-gericht dan normaal.",
            reasonByTrackID: built.reasons, trace: rendered
        )
    }

    /// Dutch label for an energy arc (diagnostics + UI).
    nonisolated static func arcLabel(_ arc: RadioSequencer.Arc) -> String {
        switch arc {
        case .smooth:     "vloeiend"
        case .gentleRise: "oplopend"
        case .peak:       "piek"
        }
    }

    /// Stable wire key for an energy arc (server ⇄ client).
    nonisolated static func arcWireKey(_ arc: RadioSequencer.Arc) -> String {
        switch arc {
        case .smooth:     "smooth"
        case .gentleRise: "gentleRise"
        case .peak:       "peak"
        }
    }

    nonisolated static func arc(fromWire key: String?) -> RadioSequencer.Arc? {
        switch key {
        case "smooth":     .smooth
        case "gentleRise": .gentleRise
        case "peak":       .peak
        default:           nil
        }
    }

    // MARK: - Server-side generation (POST /generate)

    /// Server handler: decode the wire request, run the LOCAL pipeline (this is
    /// `RoonClient.shared` on the mini, `.direct` mode, so `generatePlaylist`
    /// takes the local branch — no recursion), and encode the result. The trace
    /// is logged on the mini as a side effect of the run. Returns the full HTTP
    /// (status, body, content-type) triple so the share-server just forwards it.
    func generatePlaylistData(_ body: Data) async -> (String, Data, String) {
        guard let dto = try? JSONDecoder().decode(GenerateRequestDTO.self, from: body) else {
            return ("400 Bad Request", Data("bad generate request".utf8), "text/plain")
        }
        do {
            let result = try await generatePlaylist(
                request: dto.request, target: dto.target,
                adventurousness: dto.adventurousness, arc: Self.arc(fromWire: dto.arc),
                targetMinutes: dto.targetMinutes,
                seedArtists: dto.seedArtists, seedTrackKeys: dto.seedTrackKeys)
            guard let data = try? JSONEncoder().encode(result) else {
                return ("500 Internal Server Error", Data("encode failed".utf8), "text/plain")
            }
            return ("200 OK", data, "application/json")
        } catch is CancellationError {
            return ("499 Client Closed Request", Data("cancelled".utf8), "text/plain")
        } catch {
            // Surface the Dutch LocalizedError copy so the client shows the same
            // message a local failure would.
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ("422 Unprocessable Entity", Data(msg.utf8), "text/plain")
        }
    }

    /// Client → server-of-record: POST the request to `/generate` and decode the
    /// result (with its trace). Returns nil ONLY when the server doesn't know the
    /// endpoint (404) so the caller falls back to local generation; throws a
    /// `RemoteGenerationError` (Dutch) for a real server-side failure, and rethrows
    /// transport errors.
    private func remoteGeneratePlaylist(_ dto: GenerateRequestDTO) async throws -> GenerationResult? {
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/generate") else {
            throw RemoteGenerationError(message: "Geen verbinding met de RoonSage-server.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(dto)
        authorizeShareRequest(&req)
        req.timeoutInterval = 180   // LLM curation + naming can take a while
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw RemoteGenerationError(message: "Server onbereikbaar — probeer opnieuw.") }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200:
            guard let result = try? JSONDecoder().decode(GenerationResult.self, from: data) else {
                throw RemoteGenerationError(message: "Kon het serverantwoord niet lezen.")
            }
            return result
        case 404:
            return nil   // old server without /generate → caller runs locally
        default:
            let msg = String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Genereren mislukt op de server (\(code))."
            throw RemoteGenerationError(message: msg)
        }
    }

    /// M3 — the energy arc a request implies, from its measured activity/mood
    /// facets: high-energy contexts build to a peak, calm ones stay smooth,
    /// travel drifts up. Default is a peak journey. Deterministic, no LLM call.
    nonisolated static func suggestedArc(for filters: RequestFilters) -> RadioSequencer.Arc {
        let acts = Set(filters.activities)
        if acts.contains("workout") || acts.contains("energiek") { return .peak }
        if acts.contains("focus") || acts.contains("chillen") || acts.contains("lounge") { return .smooth }
        if acts.contains("onderweg") { return .gentleRise }
        let moods = Set(filters.moods)
        if moods.contains("party") || moods.contains("aggressive") { return .peak }
        if moods.contains("relaxed") || moods.contains("sad") { return .smooth }
        return .peak
    }

    // MARK: - Seeds (U2)

    /// Resolve user-picked seed artists + track keys into embedding-carrying
    /// `SonicTrack` anchors and the merged Deezer fan-graph. Track keys map
    /// straight through the analyzed library; each artist contributes up to
    /// `perArtistCap` of its tracks (so a prolific artist can't swamp the
    /// centroid) and its rank-weighted related-artist weights (max across seeds).
    private func resolveGenerationSeeds(
        artists: [String], trackKeys: [String],
        sonicByKey: [String: DatabaseManager.SonicTrack],
        lib: [DatabaseManager.SonicTrack], perArtistCap: Int = 3
    ) async -> (seeds: [DatabaseManager.SonicTrack], related: [String: Double]) {
        guard !artists.isEmpty || !trackKeys.isEmpty else { return ([], [:]) }
        var seeds: [DatabaseManager.SonicTrack] = []
        var seenIds = Set<String>()
        func add(_ t: DatabaseManager.SonicTrack) {
            guard seenIds.insert(t.id).inserted else { return }
            seeds.append(t)
        }
        for key in trackKeys { if let t = sonicByKey[key] { add(t) } }
        let wantArtists = Set(artists.map { $0.lowercased() })
        if !wantArtists.isEmpty {
            var perArtist: [String: Int] = [:]
            for t in lib {
                let a = (t.artist ?? "").lowercased()
                guard wantArtists.contains(a), perArtist[a, default: 0] < perArtistCap else { continue }
                perArtist[a, default: 0] += 1
                add(t)
            }
        }
        // Merged rank-weighted fan-graph across the seed artists (max weight wins).
        var related: [String: Double] = [:]
        for artist in artists {
            for (name, w) in await relatedArtistWeights(for: artist) where w > (related[name] ?? 0) {
                related[name] = w
            }
        }
        return (seeds, related)
    }

    // MARK: - Candidate pool

    /// Filter → broaden → measured mood/activity gate → soft-dislike → engine
    /// rank → cap. The rank runs over the WHOLE filtered pool (via a sub-index)
    /// and the cap is applied *after*, so the curator sees the most on-target
    /// candidates rather than a random pre-rank slice.
    func buildCandidatePool(
        request: String, filters: RequestFilters, target: Int,
        adventurousness: Double = RoonClient.defaultAdventurousness,
        sonicByKey: [String: DatabaseManager.SonicTrack] = [:],
        calibration: TitleGrounding.Calibration? = nil,
        seeds: [DatabaseManager.SonicTrack] = [],
        relatedArtists: [String: Double] = [:],
        trace: GenerationTrace? = nil
    ) async -> (pool: [TrackRecord], survived: RequestFilters, reasons: [String: String],
                sonicRanked: Bool) {
        let minPool = max(target * 3, 40)
        trace?.section("3 · Kandidatenpool")
        var opts = DatabaseManager.FilterOptions()
        opts.genres = filters.genres
        opts.decades = filters.decades
        opts.keywords = filters.keywords
        opts.tags = filters.tags
        opts.excludeLive = true
        opts.limit = 3000

        var pool = await filterTracks(options: opts)
        trace?.kv("na filter", "\(pool.count) tracks (drempel \(minPool))")
        // Broaden most-specific-first so the genre intent is the last thing dropped.
        if pool.count < minPool, !opts.tags.isEmpty     { opts.tags = [];     pool = await filterTracks(options: opts); trace?.kv("verbreed: tags weg", "\(pool.count)") }
        if pool.count < minPool, !opts.keywords.isEmpty { opts.keywords = ""; pool = await filterTracks(options: opts); trace?.kv("verbreed: trefwoorden weg", "\(pool.count)") }
        if pool.count < minPool, !opts.decades.isEmpty  { opts.decades = [];  pool = await filterTracks(options: opts); trace?.kv("verbreed: decennia weg", "\(pool.count)") }
        if pool.count < minPool, !opts.genres.isEmpty   { opts.genres = [];   pool = await filterTracks(options: opts); trace?.kv("verbreed: genres weg", "\(pool.count) (hele bibliotheek)") }

        var survived = RequestFilters(genres: opts.genres, decades: opts.decades,
                                      keywords: opts.keywords, tags: opts.tags)

        // Genre-purity gate: filterTracks matches a track tagged with the genre in
        // EITHER source, so one spurious crowd-tag (a lone "jazz" on an electronic
        // track) leaks off-genre material in. Keep only tracks whose requested
        // genre's *family* is the plurality of their tags, or is confirmed by both
        // sources — relaxing to the ungated pool when it would fall below minPool
        // (so a genuinely thin genre still fills).
        if !opts.genres.isEmpty, pool.count >= minPool, let db = database {
            let ids = pool.map(\.id)
            let keys = pool.compactMap(\.matchKey).filter { !$0.isEmpty }
            if let genres = try? await db.genresForTracks(ids: ids, matchKeys: keys) {
                let pure = pool.filter { t in
                    DatabaseManager.passesGenrePurity(
                        roon: genres.roon[t.id] ?? [],
                        mb: t.matchKey.flatMap { genres.mb[$0] } ?? [],
                        requested: opts.genres)
                }
                if pure.count >= minPool {
                    let dropped = pool.count - pure.count
                    pool = pure
                    trace?.kvIf("genre-zuiverheid", dropped > 0 ? "\(dropped) off-genre tracks weg → \(pool.count)" : "")
                } else {
                    trace?.kv("genre-zuiverheid", "verzacht (slechts \(pure.count) < \(minPool)) → ongefilterd")
                }
            }
        }

        // M2 — measured mood/activity gate (feature fusion, like the radio
        // buckets): keep only tracks whose ANALYZED character matches the
        // request's mood/activity, relaxing to the ungated pool when the
        // library can't fill it. Unanalyzed tracks fail a measured gate.
        if let gate = Self.requestGate(moods: filters.moods, activities: filters.activities,
                                       calibration: calibration), !sonicByKey.isEmpty {
            let gated = pool.filter { t in
                t.matchKey.flatMap { sonicByKey[$0] }.map(gate) ?? false
            }
            if gated.count >= minPool {
                pool = gated
                survived.moods = filters.moods
                survived.activities = filters.activities
                trace?.kv("sfeer/activiteit-gate", "toegepast → \(pool.count)")
            } else {
                trace?.kv("sfeer/activiteit-gate", "verzacht (slechts \(gated.count) < \(minPool)) → ongefilterd")
            }
        }

        // Soft dislike: drop thumbed-down artists only while plenty of pool remains
        // so a niche request still returns results.
        let disliked = Set((await feedbackArtistHints()).disliked.map { $0.lowercased() })
        if !disliked.isEmpty {
            let filtered = pool.filter { !disliked.contains(($0.artist ?? "").lowercased()) }
            if filtered.count >= minPool { let dropped = pool.count - filtered.count; pool = filtered; trace?.kvIf("dislike-drop", dropped > 0 ? "\(dropped) tracks van \(disliked.count) artiesten" : "") }
        }

        // QW3/M1 — rank the pool with the radio engine around the request's CLAP
        // embedding (multi-anchor relevance, taste steering, MMR near-dup drop,
        // adventurousness), THEN cap. Falls back to a shuffle when embeddings or
        // the analyzer text model aren't available.
        if let sel = await sonicRank(request: request, pool: pool, target: target,
                                     adventurousness: adventurousness, byKey: sonicByKey,
                                     seeds: seeds, relatedArtists: relatedArtists, trace: trace) {
            return (sel.tracks, survived, sel.reasons, true)
        }
        trace?.kv("sonische rangschikking", "NIET beschikbaar → willekeurige volgorde (geen embeddings/analyzer)")
        pool.shuffle()
        return (Array(pool.prefix(400)), survived, [:], false)
    }

    /// Engine ranking of the FILTERED pool around the request's text embedding:
    /// a sub-`VectorIndex` over the pool keeps the engine inside the request's
    /// scope, `queryAnchor` carries the "how it should sound" phrase, and the
    /// TasteVector + like/dislike pushes steer it toward the listener — exactly
    /// the machinery every radio already uses (GENERATE_AUDIT M1/QW3). Returns
    /// nil when reranking isn't possible so the caller falls back to a shuffle.
    private func sonicRank(
        request: String, pool: [TrackRecord], target: Int, adventurousness: Double,
        byKey: [String: DatabaseManager.SonicTrack],
        seeds: [DatabaseManager.SonicTrack] = [],
        relatedArtists: [String: Double] = [:],
        trace: GenerationTrace? = nil
    ) async -> (tracks: [TrackRecord], reasons: [String: String])? {
        guard useSonicEmbeddings, !pool.isEmpty, !byKey.isEmpty else {
            trace?.kv("sonische rangschikking", "uit (embeddings-vlag uit of lege pool)")
            return nil
        }
        // CLAP is English-trained; translate the (possibly Dutch) request into a
        // short English "how it should sound" phrase before embedding.
        let phrase = await sonicPhrase(for: request) ?? request
        trace?.kv("klank-frase (CLAP)", "“\(phrase)”")
        guard let queryVec = await requestTextVector(phrase) else {
            trace?.kv("tekst-embedding", "MISLUKT (analyzer/text-model onbereikbaar) → fallback")
            return nil
        }

        let lib = await radioLibrary()
        let fullIndex = await sonicVectorIndex()
        let taste = await personalTasteVector(lib: lib, index: fullIndex)
        let liked = likedMatchKeys
        let dislikedKeys = radioDislikedMatchKeys
        let known = await knownArtistKeys(lib: lib)
        let adv = adventurousness
        // U2 — with real track/artist seeds the pool cosines become track-to-track
        // (not text-anchor), so the library-calibrated σ-floor is now sound: drop
        // candidates too far from every seed for THIS library. No floor without
        // seeds (a text anchor's cosine distribution differs).
        let nnStats: VectorIndex.NNStats?
        if !seeds.isEmpty, let db = database { nnStats = await sonicCache.nnStats(from: db) }
        else { nnStats = nil }

        // Pool → SonicTracks, deduped by analyzed row id (compilation copies of
        // one recording share a matchKey and thus one SonicTrack).
        var seenIds = Set<String>()
        let poolSonic = pool.compactMap { t -> DatabaseManager.SonicTrack? in
            guard let mk = t.matchKey, let st = byKey[mk], seenIds.insert(st.id).inserted else { return nil }
            return st
        }
        // Seeds must live in the ranking index for their embeddings to anchor the
        // query — include any that aren't already in the pool (they're excluded
        // from the results by the engine, so they never appear in the playlist).
        let poolIds = Set(poolSonic.map(\.id))
        let indexTracks = poolSonic + seeds.filter { !poolIds.contains($0.id) }

        let floorValue = nnStats.map { RadioEngine.Options.floor(stats: $0, adventurousness: adv) }
        trace?.kv("engine-invoer", "\(poolSonic.count) geanalyseerd · \(seeds.count) seeds · taste-vector \(taste != nil ? "ja" : "nee") · related \(relatedArtists.count)")
        trace?.kvIf("σ-vloer", floorValue.map { String(format: "%.3f", $0) } ?? "")
        func run(floor: Double?) async -> (results: [RadioEngine.Result], rankedCount: Int) {
            await Task.detached {
                guard let subIndex = VectorIndex(tracks: indexTracks) else { return ([], 0) }
                let opts = RadioEngine.Options(
                    adventurousness: adv, poolLimit: 400, candidateK: indexTracks.count,
                    hardBanDisliked: false, sequence: false, similarityFloor: floor)
                let ranked = RadioEngine.rank(seeds: seeds, library: indexTracks, index: subIndex,
                                              options: opts, disliked: dislikedKeys, likedKeys: liked,
                                              knownArtists: known, tasteVector: taste,
                                              relatedArtists: relatedArtists,
                                              salt: "", queryAnchor: queryVec)
                // QW2 — guarantee near-duplicate removal (same recording on album +
                // compilation, different matchKeys) even on pools ≤ poolLimit, where
                // RadioEngine's internal MMR — and thus its near-dup drop — is
                // bypassed. Order-preserving; keeps the whole list (limit = count).
                let hits = ranked.map { VectorIndex.Hit(track: $0.track, score: Float($0.score)) }
                let keptIDs = Set(SonicSelection.dropNearDuplicates(hits, index: subIndex, limit: hits.count)
                    .map(\.track.id))
                return (ranked.filter { keptIDs.contains($0.track.id) }, ranked.count)
            }.value
        }
        var outcome = await run(floor: floorValue)
        // Seed/prompt-conflict guard: the σ-floor is calibrated on seed-NN
        // distances and assumes the pool sits roughly in-distribution around the
        // seeds. When the prompt's filters build a pool sonically far from the
        // seeds (a rock seed + an ambient-jazz prompt), the floor can starve the
        // engine and the caller would fall back to a shuffle. Relax it like the
        // genre/mood gates: an unfloored sonic ranking beats a random pool.
        let need = min(target, poolSonic.count)
        if let floor = floorValue, outcome.results.count < need {
            trace?.kv("σ-vloer verzacht",
                      "slechts \(outcome.results.count) gerangschikt (< \(need)) met vloer "
                      + String(format: "%.3f", floor) + " → opnieuw zonder vloer")
            outcome = await run(floor: nil)
        }
        let ranked = outcome.results
        trace?.kv("engine-uitvoer", "\(outcome.rankedCount) gerangschikt → \(ranked.count) na near-dup-drop (\(outcome.rankedCount - ranked.count) verwijderd)")
        guard !ranked.isEmpty else { return nil }

        // Map back to the ORIGINAL TrackRecords (keep imageKey/year/albumKey).
        var recByKey = [String: TrackRecord](minimumCapacity: pool.count)
        for t in pool { if let mk = t.matchKey, recByKey[mk] == nil { recByKey[mk] = t } }
        var out: [TrackRecord] = []
        var reasons: [String: String] = [:]
        for r in ranked {
            guard let rec = recByKey[r.track.matchKey] else { continue }
            out.append(rec)
            reasons[rec.id] = Self.reasonText(r.reason)
        }
        guard !out.isEmpty else { return nil }
        let rankedOut = out.count
        // Coverage guard: a partially-analysed library shouldn't shrink the pool
        // to "whatever happens to be analysed" — UNANALYZED tracks trail the
        // ranked ones (the engine's near-dup/MMR drops stay dropped).
        out += pool.filter { t in t.matchKey.flatMap { byKey[$0] } == nil }
        let final = Array(out.prefix(400))
        trace?.kv("pool klaar", "\(final.count) (\(rankedOut) sonisch gerangschikt + \(final.count - rankedOut) ongeanalyseerd achteraan)")
        return (final, reasons)
    }

    /// U3 — keep the flow-ordered prefix whose cumulative duration best meets
    /// `budgetSeconds`. Walks in order (so the journey is preserved) and stops at
    /// the track that crosses the budget, keeping it only when that lands closer
    /// to the target than stopping short. Unknown durations use the library-wide
    /// 3.5-min average. Always returns at least one track.
    nonisolated static func trimToDuration(
        _ tracks: [TrackRecord], budgetSeconds: Double, durationByKey: [String: Double]
    ) -> [TrackRecord] {
        guard budgetSeconds > 0, !tracks.isEmpty else { return tracks }
        let avg = 3.5 * 60
        func dur(_ t: TrackRecord) -> Double { t.matchKey.flatMap { durationByKey[$0] } ?? avg }
        var acc = 0.0
        var kept: [TrackRecord] = []
        for t in tracks {
            let d = dur(t)
            if acc + d <= budgetSeconds || kept.isEmpty {
                kept.append(t); acc += d
            } else {
                // Crossing the budget: include this track only if doing so lands
                // closer to the target than stopping here.
                let over = acc + d - budgetSeconds
                let under = budgetSeconds - acc
                if over < under { kept.append(t) }
                break
            }
        }
        return kept
    }

    /// The engine's Reason as generation copy. With no track seeds `.similar`
    /// means "close to the request", not "close to your seeds" — reword it;
    /// the other kinds read correctly as-is.
    nonisolated static func reasonText(_ r: RadioEngine.Reason) -> String {
        r.kind == .similar ? "Sluit aan bij je verzoek" : r.text
    }

    /// The measured mood/activity gate for a free-text request — the mood and
    /// activity semantics of `customGate` (RoonClient+CustomRadio) without the
    /// genre/decade facets, which Generate already filters in SQL. nil when the
    /// request implies neither.
    nonisolated static func requestGate(
        moods: [String], activities: [String], calibration: TitleGrounding.Calibration?
    ) -> (@Sendable (DatabaseManager.SonicTrack) -> Bool)? {
        let moodKeys = Set(moods.map { $0.lowercased() })
        let profiles = activityProfiles(calibration: calibration).filter { activities.contains($0.key) }
        if moodKeys.isEmpty, profiles.isEmpty { return nil }
        return { t in
            if !moodKeys.isEmpty {
                let dominant = t.moods.max(by: { $0.value < $1.value })?.key.lowercased()
                let ok = moodKeys.contains { mk in
                    if dominant == mk { return true }
                    return t.moods.first { $0.key.lowercased() == mk }.map { $0.value >= 0.3 } ?? false
                }
                if !ok { return false }
            }
            if !profiles.isEmpty, !profiles.contains(where: { $0.matches(t) }) { return false }
            return true
        }
    }

    /// QW1 — order the final curated set into a flowing sequence (CLAP cosine,
    /// BPM continuity, Camelot compatibility, energy arc) via `RadioSequencer`.
    /// Unanalyzed tracks ride along as neutral stubs; nothing is dropped. The
    /// stub/copy carries the TrackRecord's id so the order maps back 1:1.
    nonisolated static func flowOrder(
        _ tracks: [TrackRecord], byKey: [String: DatabaseManager.SonicTrack],
        arc: RadioSequencer.Arc
    ) -> [TrackRecord] {
        guard tracks.count > 2 else { return tracks }
        let nodes = tracks.map { t -> DatabaseManager.SonicTrack in
            if let mk = t.matchKey, var st = byKey[mk] {
                st.id = t.id   // sequence over the playlist's own row identity
                return st
            }
            return DatabaseManager.SonicTrack(
                id: t.id, title: t.title, artist: t.artist, album: t.album,
                imageKey: t.imageKey, matchKey: t.matchKey ?? "",
                bpm: nil, camelot: "", energy: nil, tags: [])
        }
        let byId = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return RadioSequencer.order(nodes, arc: arc).compactMap { byId[$0.id] }
    }

    // MARK: - Taste

    func tasteContext(pool: [TrackRecord]) async -> TasteContext {
        let top = (await tasteProfile(topLimit: 30, recentLimit: 1))?.topArtists ?? []
        let hints = await feedbackArtistHints()
        // Trim liked artists to those actually present in the pool (cap) so small
        // local models don't waste context on irrelevant names.
        let poolArtists = Set(pool.compactMap { $0.artist?.lowercased() })
        let liked = hints.liked.filter { poolArtists.contains($0.lowercased()) }.prefix(12)
        return TasteContext(
            preferred: Set(top.map { $0.artist.lowercased() }),
            liked: Array(liked),
            disliked: Array(hints.disliked.prefix(12)),
            deprioritized: Set(recentlyGeneratedIdentities)
        )
    }

    /// The liked/disliked prompt block, shared so Generate and Recommend phrase
    /// taste identically. `inPool` (Generate) trims to relevant artists.
    public func feedbackPromptBlock() async -> String {
        let hints = await feedbackArtistHints()
        return Self.tasteBlock(liked: Array(hints.liked.prefix(20)),
                               disliked: Array(hints.disliked.prefix(20)))
    }

    static func tasteBlock(liked: [String], disliked: [String]) -> String {
        var s = ""
        if !liked.isEmpty {
            s += "\n\nArtists the listener likes (favor similar): \(liked.joined(separator: ", "))"
        }
        if !disliked.isEmpty {
            s += "\nArtists the listener dislikes (avoid unless the request explicitly asks): \(disliked.joined(separator: ", "))"
        }
        return s
    }

    // MARK: - Curation

    private func curate(
        request: String, target: Int, candidates: [TrackRecord],
        taste: TasteContext, sonic: [String: DatabaseManager.SonicTrack] = [:],
        config: LLMConfig, trace: GenerationTrace? = nil
    ) async throws -> (tracks: [TrackRecord], aiCurated: Bool) {
        // The model sees the top slice (token budget); the assembler tops up from
        // the full ranked pool, so `picks` index into `llmList`.
        let llmList = Array(candidates.prefix(220))
        let list = llmList.enumerated().map { i, t -> String in
            var s = "\(i + 1). \(t.title)"
            if let a = t.artist { s += " — \(a)" }
            if let y = t.year   { s += " (\(y))" }
            // QW4 — measured sonic hints so the model curates on how a track
            // SOUNDS, not on name recognition. Compact: [mood, bpm].
            if let st = t.matchKey.flatMap({ sonic[$0] }) {
                var hints: [String] = []
                if let top = st.moods.max(by: { $0.value < $1.value }), top.value >= 0.3 {
                    hints.append(top.key)
                }
                if let b = st.bpm, b > 0 { hints.append("\(Int(b.rounded())) bpm") }
                if !hints.isEmpty { s += " [\(hints.joined(separator: ", "))]" }
            }
            return s
        }.joined(separator: "\n")

        let system = """
        You are a music curator for a personal Roon music player. \
        Select exactly \(target) tracks from the numbered list (numbers 1 to \(llmList.count)) that best match the request. \
        Tracks may carry [mood, bpm] hints MEASURED from the audio — trust them over what a title suggests. \
        Rules: max 2 tracks per artist, no two consecutive tracks by the same artist, ensure variety. \
        Lean toward artists the listener favors and avoid those they dislike, unless the request explicitly asks for them. \
        Return ONLY the track numbers separated by commas — no explanation, no extra text. \
        Example: 3, 17, 42, 8, 91
        """
        let user = "Request: \(request)\(Self.tasteBlock(liked: taste.liked, disliked: taste.disliked))\n\nAvailable tracks:\n\(list)"

        func resolve(_ response: String) -> [TrackRecord] {
            PlaylistAssembler.picks(from: response, max: llmList.count).compactMap { n in
                (n >= 1 && n <= llmList.count) ? llmList[n - 1] : nil
            }
        }
        func assemble(_ picks: [TrackRecord]) -> [TrackRecord] {
            PlaylistAssembler.assemble(
                llmPicks: picks, pool: candidates, target: target, maxPerArtist: 2,
                preferredArtists: taste.preferred, deprioritized: taste.deprioritized
            )
        }
        let floor = Swift.max(3, target / 3)
        trace?.kv("aan model getoond", "\(llmList.count) tracks (van \(candidates.count)) · doel \(target) · ondergrens \(floor)")

        // First attempt (throws on a real LLM failure → surfaces a Dutch error).
        var picks = resolve(try await LLMClient.shared.complete(
            system: system, user: user, config: config, temperature: 0.3, maxTokens: 512))
        trace?.kv("1e poging", "\(picks.count) geldige picks")
        if picks.count >= floor {
            let out = assemble(picks); trace?.kv("assemblage", "\(out.count) tracks (AI-gecureerd)"); return (out, true)
        }

        // Under-delivered (chatty/short reply) — one retry, slightly warmer.
        if let retry = try? await LLMClient.shared.complete(
            system: system, user: user, config: config, temperature: 0.5, maxTokens: 512) {
            let retryPicks = resolve(retry)
            trace?.kv("2e poging (warmer)", "\(retryPicks.count) picks")
            if retryPicks.count >= floor {
                let out = assemble(retryPicks); trace?.kv("assemblage", "\(out.count) tracks (AI-gecureerd, retry)"); return (out, true)
            }
            if retryPicks.count > picks.count { picks = retryPicks }
        }
        // Honest top-up: assemble from whatever the LLM gave + the ranked pool, but
        // flag it so the UI doesn't present a fallback as an AI curation.
        let out = assemble(picks)
        trace?.kv("assemblage", "\(out.count) tracks — LLM ONDER-leverde (\(picks.count) < \(floor)), aangevuld uit de pool")
        return (out, false)
    }

    // MARK: - Naming

    /// LLM stage 4: an evocative Dutch title + one-line description, GROUNDED in
    /// measured audio (QW5): the prompt carries the selection's sonic profile and
    /// a title whose style claims contradict the measurements gets one corrective
    /// retry (`TitleGrounding.violations` — the custom-radio machinery). Falls
    /// back to a heuristic, claim-free name on failure. Title is length-clamped.
    func describePlaylist(
        request: String, tracks: [TrackRecord],
        sonic: [String: DatabaseManager.SonicTrack] = [:],
        calibration: TitleGrounding.Calibration? = nil,
        config: LLMConfig, trace: GenerationTrace? = nil
    ) async -> (title: String, description: String?) {
        let sample = tracks.prefix(30).map { t -> String in
            var s = t.title; if let a = t.artist { s += " — \(a)" }; return s
        }.joined(separator: "\n")
        let sonicSel = tracks.compactMap { t in t.matchKey.flatMap { sonic[$0] } }
        let stats = sonicSel.isEmpty ? nil : TitleGrounding.SelectionStats.compute(sonicSel)
        let profile = sonicSel.isEmpty ? ""
            : Self.sonicProfileSummary(sonicSel, includeAttributes: true, calibration: calibration)
        trace?.section("6 · Titel (LLM, gegrond)")
        trace?.kvIf("gemeten profiel", profile)

        let system = """
        Je geeft een Nederlandse muziekplaylist een naam en korte beschrijving. \
        Antwoord met UITSLUITEND een JSON-object, geen andere tekst: {"title": "", "description": ""} \
        - title: een korte, sprekende Nederlandse naam (max 5 woorden), zonder aanhalingstekens, zonder emoji. \
        - description: één of twee warme Nederlandse zinnen die de sfeer van de set vangen. \
        Baseer stijl- en sfeerwoorden (rustig, energiek, akoestisch, dansbaar, …) UITSLUITEND op het \
        gemeten sonische profiel als dat gegeven is; beweer geen kenmerken die er niet in staan.
        """
        var user = "Verzoek van de gebruiker: \(request)"
        if !profile.isEmpty {
            user += "\nSonisch profiel van de selectie (GEMETEN uit de audio): \(profile)"
        }
        user += "\n\nTracks:\n\(sample)"

        func attempt(_ prompt: String) async -> (title: String, description: String?)? {
            guard let resp = try? await LLMClient.shared.complete(
                    system: system, user: prompt, config: config,
                    jsonMode: true, temperature: 0.7, maxTokens: 256),
                  let obj = Self.firstJSONObject(resp) else { return nil }
            let rawTitle = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let desc = (obj["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rawTitle, !rawTitle.isEmpty else { return nil }
            return (Self.clampTitle(rawTitle, max: 45), (desc?.isEmpty == false) ? desc : nil)
        }

        guard let first = await attempt(user) else {
            trace?.kv("titel", "LLM gaf niets → heuristische fallback")
            return (Self.fallbackTitle(request), nil)
        }
        guard let stats else { trace?.kv("titel", "“\(first.title)” (geen meting om te toetsen)"); return first }
        let bad = TitleGrounding.violations(title: first.title, stats: stats, calibration: calibration)
        guard !bad.isEmpty else { trace?.kv("titel", "“\(first.title)” (gegrond ✓)"); return first }
        trace?.kv("titel afgekeurd", "“\(first.title)” — spreekt meting tegen: \(bad.joined(separator: "; "))")
        let corrective = user + "\n\nLET OP — je eerdere titel “\(first.title)” bevatte claims die de metingen tegenspreken: \(bad.joined(separator: "; ")). Maak een nieuwe titel ZONDER deze woorden, trouw aan het gemeten profiel."
        if let retry = await attempt(corrective),
           TitleGrounding.violations(title: retry.title, stats: stats, calibration: calibration).isEmpty {
            trace?.kv("titel na retry", "“\(retry.title)” (gegrond ✓)")
            return retry
        }
        // Still contradicting the audio → the honest, claim-free fallback.
        trace?.kv("titel", "retry faalde → heuristische fallback")
        return (Self.fallbackTitle(request), first.description)
    }

    static func fallbackTitle(_ request: String) -> String {
        let trimmed = request.prefix(48).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Gegenereerde playlist" : String(trimmed)
    }

    // MARK: - Anti-repetition

    func rememberGenerated(_ tracks: [TrackRecord]) {
        let ids = tracks.map { PlaylistAssembler.identity($0) }
        recentlyGeneratedIdentities = Array((recentlyGeneratedIdentities + ids).suffix(240))
    }
}
