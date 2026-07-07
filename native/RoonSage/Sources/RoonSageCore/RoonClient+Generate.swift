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
    public struct GenerationResult: Sendable {
        public var tracks: [TrackRecord]
        public var filters: RequestFilters     // the scope that survived broadening
        public var poolSize: Int
        public var title: String
        public var description: String?
        public var droppedNote: String?        // genre intent couldn't be honoured
        public var aiCurated: Bool             // false = top-up only (LLM under-delivered)
        /// Per-track "waarom deze track" (RadioEngine.Reason, NL), keyed by
        /// TrackRecord.id. Empty when the engine path wasn't available.
        public var reasonByTrackID: [String: String] = [:]
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
    /// `arc` is the energy shape the final set is flow-ordered into.
    public func generatePlaylist(
        request: String, target: Int,
        adventurousness: Double = RoonClient.defaultAdventurousness,
        arc: RadioSequencer.Arc = .peak,
        onProgress: ((GenerationPhase) -> Void)? = nil
    ) async throws -> GenerationResult {
        let config = effectiveLLMConfig()

        // Stage 1 — analyse the request into library filters (genres/tags/decades
        // + measured moods/activities).
        try Task.checkCancellation()
        onProgress?(.analyzing)
        let analysis = await analyzeForFilters(request: request)

        // Shared sonic context for the whole pipeline: the analyzed library keyed
        // by content, plus the library calibration that makes mood/energy
        // judgements library-relative. Engine ranking, curator hints, the flow
        // sequencer and the grounded title all read from this one snapshot.
        let lib = await radioLibrary()
        let sonicByKey = Dictionary(lib.filter { !$0.matchKey.isEmpty }.map { ($0.matchKey, $0) },
                                    uniquingKeysWith: { a, _ in a })
        let calibration: TitleGrounding.Calibration? = lib.isEmpty ? nil
            : await Task.detached { TitleGrounding.Calibration.compute(library: lib) }.value

        // Stage 2 — build a sonically-ranked candidate pool (broadened as needed).
        try Task.checkCancellation()
        onProgress?(.candidates)
        let built = await buildCandidatePool(request: request, filters: analysis, target: target,
                                             adventurousness: adventurousness,
                                             sonicByKey: sonicByKey, calibration: calibration)
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
        let curated = try await curate(request: request, target: target,
                                       candidates: candidates, taste: taste,
                                       sonic: sonicByKey, config: config)
        guard !curated.tracks.isEmpty else { throw GenerationError.emptyResult }
        // QW1 — order the set into a designed journey (CLAP/BPM/key/energy-arc)
        // instead of leaving it in LLM pick order.
        let picks = curated.tracks
        let ordered = await Task.detached { Self.flowOrder(picks, byKey: sonicByKey, arc: arc) }.value

        // Stage 4 — grounded AI title + description (Dutch).
        try Task.checkCancellation()
        onProgress?(.naming)
        let meta = await describePlaylist(request: request, tracks: ordered,
                                          sonic: sonicByKey, calibration: calibration, config: config)

        // Only record into the anti-repetition trail once the result is final and
        // not cancelled — a stopped generation the user never saw shouldn't bias
        // the next one.
        try Task.checkCancellation()
        rememberGenerated(ordered)
        return GenerationResult(
            tracks: ordered, filters: survived, poolSize: candidates.count,
            title: meta.title, description: meta.description,
            droppedNote: droppedNote, aiCurated: curated.aiCurated,
            reasonByTrackID: built.reasons
        )
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
        calibration: TitleGrounding.Calibration? = nil
    ) async -> (pool: [TrackRecord], survived: RequestFilters, reasons: [String: String]) {
        let minPool = max(target * 3, 40)
        var opts = DatabaseManager.FilterOptions()
        opts.genres = filters.genres
        opts.decades = filters.decades
        opts.keywords = filters.keywords
        opts.tags = filters.tags
        opts.excludeLive = true
        opts.limit = 3000

        var pool = await filterTracks(options: opts)
        // Broaden most-specific-first so the genre intent is the last thing dropped.
        if pool.count < minPool, !opts.tags.isEmpty     { opts.tags = [];     pool = await filterTracks(options: opts) }
        if pool.count < minPool, !opts.keywords.isEmpty { opts.keywords = ""; pool = await filterTracks(options: opts) }
        if pool.count < minPool, !opts.decades.isEmpty  { opts.decades = [];  pool = await filterTracks(options: opts) }
        if pool.count < minPool, !opts.genres.isEmpty   { opts.genres = [];   pool = await filterTracks(options: opts) }

        var survived = RequestFilters(genres: opts.genres, decades: opts.decades,
                                      keywords: opts.keywords, tags: opts.tags)

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
            }
        }

        // Soft dislike: drop thumbed-down artists only while plenty of pool remains
        // so a niche request still returns results.
        let disliked = Set((await feedbackArtistHints()).disliked.map { $0.lowercased() })
        if !disliked.isEmpty {
            let filtered = pool.filter { !disliked.contains(($0.artist ?? "").lowercased()) }
            if filtered.count >= minPool { pool = filtered }
        }

        // QW3/M1 — rank the pool with the radio engine around the request's CLAP
        // embedding (multi-anchor relevance, taste steering, MMR near-dup drop,
        // adventurousness), THEN cap. Falls back to a shuffle when embeddings or
        // the analyzer text model aren't available.
        if let sel = await sonicRank(request: request, pool: pool,
                                     adventurousness: adventurousness, byKey: sonicByKey) {
            return (sel.tracks, survived, sel.reasons)
        }
        pool.shuffle()
        return (Array(pool.prefix(400)), survived, [:])
    }

    /// Engine ranking of the FILTERED pool around the request's text embedding:
    /// a sub-`VectorIndex` over the pool keeps the engine inside the request's
    /// scope, `queryAnchor` carries the "how it should sound" phrase, and the
    /// TasteVector + like/dislike pushes steer it toward the listener — exactly
    /// the machinery every radio already uses (GENERATE_AUDIT M1/QW3). Returns
    /// nil when reranking isn't possible so the caller falls back to a shuffle.
    private func sonicRank(
        request: String, pool: [TrackRecord], adventurousness: Double,
        byKey: [String: DatabaseManager.SonicTrack]
    ) async -> (tracks: [TrackRecord], reasons: [String: String])? {
        guard useSonicEmbeddings, !pool.isEmpty, !byKey.isEmpty else { return nil }
        // CLAP is English-trained; translate the (possibly Dutch) request into a
        // short English "how it should sound" phrase before embedding.
        let phrase = await sonicPhrase(for: request) ?? request
        guard let queryVec = await requestTextVector(phrase) else { return nil }

        let lib = await radioLibrary()
        let fullIndex = await sonicVectorIndex()
        let taste = await personalTasteVector(lib: lib, index: fullIndex)
        let liked = likedMatchKeys
        let dislikedKeys = radioDislikedMatchKeys
        let known = await knownArtistKeys(lib: lib)
        let adv = adventurousness

        // Pool → SonicTracks, deduped by analyzed row id (compilation copies of
        // one recording share a matchKey and thus one SonicTrack).
        var seenIds = Set<String>()
        let poolSonic = pool.compactMap { t -> DatabaseManager.SonicTrack? in
            guard let mk = t.matchKey, let st = byKey[mk], seenIds.insert(st.id).inserted else { return nil }
            return st
        }

        let ranked: [RadioEngine.Result] = await Task.detached {
            guard let subIndex = VectorIndex(tracks: poolSonic) else { return [] }
            let opts = RadioEngine.Options(
                adventurousness: adv, poolLimit: 400, candidateK: poolSonic.count,
                hardBanDisliked: false, sequence: false)
            let ranked = RadioEngine.rank(seeds: [], library: poolSonic, index: subIndex,
                                          options: opts, disliked: dislikedKeys, likedKeys: liked,
                                          knownArtists: known, tasteVector: taste,
                                          salt: "", queryAnchor: queryVec)
            // QW2 — guarantee near-duplicate removal (same recording on album +
            // compilation, different matchKeys) even on pools ≤ poolLimit, where
            // RadioEngine's internal MMR — and thus its near-dup drop — is
            // bypassed. Order-preserving; keeps the whole list (limit = count).
            let hits = ranked.map { VectorIndex.Hit(track: $0.track, score: Float($0.score)) }
            let keptIDs = Set(SonicSelection.dropNearDuplicates(hits, index: subIndex, limit: hits.count)
                .map(\.track.id))
            return ranked.filter { keptIDs.contains($0.track.id) }
        }.value
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
        // Coverage guard: a partially-analysed library shouldn't shrink the pool
        // to "whatever happens to be analysed" — UNANALYZED tracks trail the
        // ranked ones (the engine's near-dup/MMR drops stay dropped).
        out += pool.filter { t in t.matchKey.flatMap { byKey[$0] } == nil }
        return (Array(out.prefix(400)), reasons)
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
        config: LLMConfig
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

        // First attempt (throws on a real LLM failure → surfaces a Dutch error).
        var picks = resolve(try await LLMClient.shared.complete(
            system: system, user: user, config: config, temperature: 0.3, maxTokens: 512))
        if picks.count >= floor { return (assemble(picks), true) }

        // Under-delivered (chatty/short reply) — one retry, slightly warmer.
        if let retry = try? await LLMClient.shared.complete(
            system: system, user: user, config: config, temperature: 0.5, maxTokens: 512) {
            let retryPicks = resolve(retry)
            if retryPicks.count >= floor { return (assemble(retryPicks), true) }
            if retryPicks.count > picks.count { picks = retryPicks }
        }
        // Honest top-up: assemble from whatever the LLM gave + the ranked pool, but
        // flag it so the UI doesn't present a fallback as an AI curation.
        return (assemble(picks), false)
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
        config: LLMConfig
    ) async -> (title: String, description: String?) {
        let sample = tracks.prefix(30).map { t -> String in
            var s = t.title; if let a = t.artist { s += " — \(a)" }; return s
        }.joined(separator: "\n")
        let sonicSel = tracks.compactMap { t in t.matchKey.flatMap { sonic[$0] } }
        let stats = sonicSel.isEmpty ? nil : TitleGrounding.SelectionStats.compute(sonicSel)
        let profile = sonicSel.isEmpty ? ""
            : Self.sonicProfileSummary(sonicSel, includeAttributes: true, calibration: calibration)

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

        guard let first = await attempt(user) else { return (Self.fallbackTitle(request), nil) }
        guard let stats else { return first }
        let bad = TitleGrounding.violations(title: first.title, stats: stats, calibration: calibration)
        guard !bad.isEmpty else { return first }
        let corrective = user + "\n\nLET OP — je eerdere titel “\(first.title)” bevatte claims die de metingen tegenspreken: \(bad.joined(separator: "; ")). Maak een nieuwe titel ZONDER deze woorden, trouw aan het gemeten profiel."
        if let retry = await attempt(corrective),
           TitleGrounding.violations(title: retry.title, stats: stats, calibration: calibration).isEmpty {
            return retry
        }
        // Still contradicting the audio → the honest, claim-free fallback.
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
