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
    public func generatePlaylist(
        request: String, target: Int,
        onProgress: ((GenerationPhase) -> Void)? = nil
    ) async throws -> GenerationResult {
        let config = effectiveLLMConfig()

        // Stage 1 — analyse the request into library filters (genres/tags/decades).
        try Task.checkCancellation()
        onProgress?(.analyzing)
        let analysis = await analyzeForFilters(request: request)

        // Stage 2 — build a sonically-ranked candidate pool (broadened as needed).
        try Task.checkCancellation()
        onProgress?(.candidates)
        let built = await buildCandidatePool(request: request, filters: analysis, target: target)
        guard !built.pool.isEmpty else { throw GenerationError.noCandidates }
        let candidates = built.pool
        let survived = built.survived

        // Warn when a genre/mood was asked for but the library couldn't honour it.
        let wantedScope = !analysis.genres.isEmpty || !analysis.tags.isEmpty
        let lostScope = survived.genres.isEmpty && survived.tags.isEmpty
        let droppedNote = (wantedScope && lostScope)
            ? "Te weinig tracks voor dit genre in je bibliotheek — gekozen uit de hele bibliotheek."
            : nil

        // Stage 3 — LLM curation + deterministic assembly.
        try Task.checkCancellation()
        onProgress?(.curating)
        let taste = await tasteContext(pool: candidates)
        let curated = try await curate(request: request, target: target,
                                       candidates: candidates, taste: taste, config: config)
        guard !curated.tracks.isEmpty else { throw GenerationError.emptyResult }

        // Stage 4 — AI title + description (Dutch).
        try Task.checkCancellation()
        onProgress?(.naming)
        let meta = await describePlaylist(request: request, tracks: curated.tracks, config: config)

        // Only record into the anti-repetition trail once the result is final and
        // not cancelled — a stopped generation the user never saw shouldn't bias
        // the next one.
        try Task.checkCancellation()
        rememberGenerated(curated.tracks)
        return GenerationResult(
            tracks: curated.tracks, filters: survived, poolSize: candidates.count,
            title: meta.title, description: meta.description,
            droppedNote: droppedNote, aiCurated: curated.aiCurated
        )
    }

    // MARK: - Candidate pool

    /// Filter → broaden → soft-dislike → sonic-rerank → cap. The rerank runs over
    /// the WHOLE filtered pool and the cap is applied *after*, so the curator sees
    /// the most on-target candidates rather than a random pre-rerank slice.
    func buildCandidatePool(
        request: String, filters: RequestFilters, target: Int
    ) async -> (pool: [TrackRecord], survived: RequestFilters) {
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

        let survived = RequestFilters(genres: opts.genres, decades: opts.decades,
                                      keywords: opts.keywords, tags: opts.tags)

        // Soft dislike: drop thumbed-down artists only while plenty of pool remains
        // so a niche request still returns results.
        let disliked = Set((await feedbackArtistHints()).disliked.map { $0.lowercased() })
        if !disliked.isEmpty {
            let filtered = pool.filter { !disliked.contains(($0.artist ?? "").lowercased()) }
            if filtered.count >= minPool { pool = filtered }
        }

        // Rerank the full pool by sonic closeness to the request, THEN cap. Falls
        // back to a shuffle when embeddings/the analyzer text model aren't available.
        let ranked: [TrackRecord]
        if let r = await sonicRerank(request, pool, limit: pool.count, maxPerArtist: 5) {
            ranked = r
        } else {
            pool.shuffle()
            ranked = pool
        }
        return (Array(ranked.prefix(400)), survived)
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
        taste: TasteContext, config: LLMConfig
    ) async throws -> (tracks: [TrackRecord], aiCurated: Bool) {
        // The model sees the top slice (token budget); the assembler tops up from
        // the full ranked pool, so `picks` index into `llmList`.
        let llmList = Array(candidates.prefix(220))
        let list = llmList.enumerated().map { i, t -> String in
            var s = "\(i + 1). \(t.title)"
            if let a = t.artist { s += " — \(a)" }
            if let y = t.year   { s += " (\(y))" }
            return s
        }.joined(separator: "\n")

        let system = """
        You are a music curator for a personal Roon music player. \
        Select exactly \(target) tracks from the numbered list (numbers 1 to \(llmList.count)) that best match the request. \
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

    /// LLM stage 4: an evocative Dutch title + one-line description. Falls back to
    /// a heuristic name (no description) on failure. Title is length-clamped.
    func describePlaylist(
        request: String, tracks: [TrackRecord], config: LLMConfig
    ) async -> (title: String, description: String?) {
        let sample = tracks.prefix(30).map { t -> String in
            var s = t.title; if let a = t.artist { s += " — \(a)" }; return s
        }.joined(separator: "\n")
        let system = """
        Je geeft een Nederlandse muziekplaylist een naam en korte beschrijving. \
        Antwoord met UITSLUITEND een JSON-object, geen andere tekst: {"title": "", "description": ""} \
        - title: een korte, sprekende Nederlandse naam (max 5 woorden), zonder aanhalingstekens, zonder emoji. \
        - description: één of twee warme Nederlandse zinnen die de sfeer van de set vangen.
        """
        let user = "Verzoek van de gebruiker: \(request)\n\nTracks:\n\(sample)"
        guard let resp = try? await LLMClient.shared.complete(
                system: system, user: user, config: config,
                jsonMode: true, temperature: 0.7, maxTokens: 256),
              let obj = Self.firstJSONObject(resp) else {
            return (Self.fallbackTitle(request), nil)
        }
        let rawTitle = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = (obj["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (rawTitle?.isEmpty == false) ? Self.clampTitle(rawTitle!, max: 45) : Self.fallbackTitle(request)
        return (title, (desc?.isEmpty == false) ? desc : nil)
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
