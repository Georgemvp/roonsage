import Foundation

// MARK: - Custom (user-composed) sonic radios
//
// A `RadioConfig` is a named bundle of seed facets the user assembles: any mix of
// artists, tracks, genres, moods and activities (optionally decades). This file
// wires it end to end:
//
//   • CRUD over the server-of-record (`isRemote` → HTTP `/radio-configs`, else DB).
//   • Seed resolution + a combined measured GATE (the plan's "intersection with
//     relaxation"): seed-only facets (artist/track) shape the CLAP centroid; the
//     genre/mood/activity/decade facets both seed AND gate the candidate pool.
//   • Materialisation into a `SonicRadioPlaylist` (reusing the artist-radio
//     builder) and mirroring to Qobuz under a DISTINCT name prefix so the AI-radio
//     reconciliation never touches these (and vice versa).
//   • Playback as an endless station via the shared `startRadio` machinery.

@MainActor
extension RoonClient {

    // MARK: CRUD (client app ↔ share server, or direct DB)

    /// All custom radio configs. Client apps read the server-of-record over HTTP;
    /// the always-on server reads its DB directly.
    public func radioConfigs() async -> [RadioConfig] {
        if isRemote { return await fetchRemoteRadioConfigs() }
        guard let db = database else { return [] }
        return (try? await db.listRadioConfigs()) ?? []
    }

    /// One config by id (used by the playback gate lookup).
    public func radioConfig(id: String) async -> RadioConfig? {
        await radioConfigs().first { $0.id == id }
    }

    /// Create or update a config (POST doubles as upsert). Returns success.
    @discardableResult
    public func saveRadioConfig(_ config: RadioConfig) async -> Bool {
        if isRemote { return await postRadioConfig(config) }
        guard let db = database else { return false }
        do { try await db.upsertRadioConfig(config); return true }
        catch { return false }
    }

    public func deleteRadioConfig(id: String) async {
        if isRemote { await deleteRemoteRadioConfig(id: id); return }
        try? await database?.deleteRadioConfig(id: id)
    }

    // MARK: Remote HTTP helpers

    private func fetchRemoteRadioConfigs() async -> [RadioConfig] {
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/radio-configs") else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 8
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode([RadioConfig].self, from: data) else { return [] }
        return list
    }

    private func postRadioConfig(_ config: RadioConfig) async -> Bool {
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/radio-configs") else {
            reportError("Geen verbinding met de RoonSage-server.")
            return false
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(config)
        authorizeShareRequest(&req)
        req.timeoutInterval = 15
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            reportError("Radio opslaan mislukt — is de RoonSage-server bereikbaar?")
            return false
        }
        return true
    }

    private func deleteRemoteRadioConfig(id: String) async {
        guard let base = remoteBaseURL,
              let enc = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(base)/radio-configs?id=\(enc)") else { return }
        var req = URLRequest(url: url); req.httpMethod = "DELETE"
        authorizeShareRequest(&req); req.timeoutInterval = 8
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200 { return }
        reportError("Radio verwijderen mislukt — is de RoonSage-server bereikbaar?")
    }

    // MARK: Seed resolution + combined gate (shared by playback + materialisation)

    /// The measured gate for a custom config: the genre/mood/activity/decade facets
    /// AND-ed together, with OR *within* each facet (multiple genres → match any).
    /// Seed-only facets (artist/track) contribute no gate — proximity defines them,
    /// exactly like the artist and song radios. Returns nil when no gated facet is
    /// set (then the CLAP neighbourhood alone defines the station).
    nonisolated static func customGate(
        cfg: RadioConfig,
        genres: [String: Set<String>],
        years: [String: Int],
        calibration: TitleGrounding.Calibration?
    ) -> (@Sendable (DatabaseManager.SonicTrack) -> Bool)? {
        let genreKeys = Set(cfg.genres.map { $0.lowercased() })
        let moodKeys  = Set(cfg.moods.map { $0.lowercased() })
        let decades   = Set(cfg.decades)
        let profiles  = activityProfiles(calibration: calibration).filter { cfg.activities.contains($0.key) }
        if genreKeys.isEmpty, moodKeys.isEmpty, decades.isEmpty, profiles.isEmpty { return nil }
        return { t in
            if !genreKeys.isEmpty {
                let g = genres[t.id] ?? []
                if !g.contains(where: { genreKeys.contains($0.lowercased()) }) { return false }
            }
            if !moodKeys.isEmpty {
                let dominant = t.moods.max(by: { $0.value < $1.value })?.key.lowercased()
                let ok = moodKeys.contains { mk in
                    if dominant == mk { return true }
                    return t.moods.first { $0.key.lowercased() == mk }.map { $0.value >= 0.3 } ?? false
                }
                if !ok { return false }
            }
            if !profiles.isEmpty, !profiles.contains(where: { $0.matches(t) }) { return false }
            if !decades.isEmpty {
                guard let y = years[t.matchKey], isPlausibleYear(y), decades.contains((y / 10) * 10) else { return false }
            }
            return true
        }
    }

    /// Resolve a config's facets into the centroid seed ids. Seed pool = the UNION
    /// of every facet's tracks (artist/track by identity; genre/mood/activity/decade
    /// by the combined gate), dislike-filtered, daily-shuffled and capped like a
    /// bucket. The centroid of these seeds is the station's sound.
    nonisolated static func resolveCustomSeeds(
        cfg: RadioConfig, lib: [DatabaseManager.SonicTrack],
        genres: [String: Set<String>], years: [String: Int],
        calibration: TitleGrounding.Calibration?, disliked: Set<String>, daySeed: String
    ) -> [String] {
        let artistKeys = Set(cfg.artists.map { $0.lowercased() })
        let trackKeys  = Set(cfg.trackKeys)
        let gate = customGate(cfg: cfg, genres: genres, years: years, calibration: calibration)
        var seen = Set<String>()
        var pool: [DatabaseManager.SonicTrack] = []
        for t in lib {
            guard !disliked.contains(t.matchKey) else { continue }
            var hit = false
            if !artistKeys.isEmpty, let a = t.artist?.lowercased(), artistKeys.contains(a) { hit = true }
            if !hit, !trackKeys.isEmpty, trackKeys.contains(t.matchKey) { hit = true }
            if !hit, let gate, gate(t) { hit = true }
            guard hit, seen.insert(t.id).inserted else { continue }
            pool.append(t)
        }
        let shuffled = dailyShuffled(pool, seed: daySeed)
        return Array(shuffled.prefix(radioMaxSeeds)).map(\.id)
    }

    // MARK: AI title + description (parity with the AI radios)

    /// The tidy default title/description when the LLM can't produce one — the
    /// user's name plus a facet summary. Kept as the plan's fallback so a failed
    /// generation reuses it without freezing it into the cache.
    nonisolated static func customFallbackMeta(cfg: RadioConfig) -> (title: String, description: String) {
        (cfg.name.isEmpty ? "Mijn radio" : cfg.name, customRadioDescription(cfg))
    }

    /// Ask the LLM for a Dutch title + description for a user-composed radio, using
    /// the SAME grounding machinery as the AI radios (sonic profile + measured
    /// stats + violation retry). The user's name and chosen facets steer the theme.
    /// Returns nil on failure so the caller reuses the fallback WITHOUT caching it.
    nonisolated static func generateCustomAIMeta(
        cfg: RadioConfig, sample: [TrackRecord], profile: String,
        stats: TitleGrounding.SelectionStats?, calibration: TitleGrounding.Calibration?
    ) async -> (title: String, description: String)? {
        let fallback = customFallbackMeta(cfg: cfg)

        // Describe what the user composed the radio from (the theme for the prompt).
        var facetBits: [String] = []
        if !cfg.artists.isEmpty { facetBits.append("artiesten: \(cfg.artists.prefix(4).joined(separator: ", "))") }
        if !cfg.genres.isEmpty { facetBits.append("genres: \(cfg.genres.prefix(4).map { $0.capitalized }.joined(separator: ", "))") }
        if !cfg.moods.isEmpty { facetBits.append("sfeer: \(cfg.moods.prefix(3).map { moodLabel($0) }.joined(separator: ", "))") }
        if !cfg.activities.isEmpty {
            let labels = activityProfiles(calibration: nil).filter { cfg.activities.contains($0.key) }.map(\.label)
            facetBits.append("activiteit: \(labels.joined(separator: ", "))")
        }
        if !cfg.decades.isEmpty {
            facetBits.append("periode: \(cfg.decades.sorted().map { $0 >= 2000 ? "jaren \($0)" : "jaren \($0 % 100)" }.joined(separator: ", "))")
        }
        let theme = facetBits.isEmpty ? "een eigen selectie" : facetBits.joined(separator: "; ")
        let named = cfg.name.trimmingCharacters(in: .whitespaces)

        let examples = sample.prefix(8).map { "• \($0.title) — \($0.artist ?? "onbekend")" }.joined(separator: "\n")
        let artists = Array(Set(sample.compactMap(\.artist))).prefix(6).joined(separator: ", ")

        let system = """
        Je bent een muziekredacteur die pakkende, INFORMATIEVE Nederlandse playlist-titels schrijft. \
        Antwoord UITSLUITEND met strikt geldige JSON, exact in de vorm \
        {"title": "...", "description": "..."}. Geen uitleg, geen markdown, geen codeblok.
        """
        let user = """
        Maak een titel en korte beschrijving voor een zelf samengestelde radio-playlist\(named.isEmpty ? "" : " met het thema ‘\(named)’").

        Waar de gebruiker de radio uit samenstelde: \(theme)
        Sonisch profiel van de selectie (GEMETEN uit de audio): \(profile.isEmpty ? "onbekend" : profile)
        Voorbeeldtracks:
        \(examples)
        Kenmerkende artiesten: \(artists.isEmpty ? "diverse" : artists)

        Eisen voor "title":
        - Maak METEEN duidelijk wat voor muziek/sfeer het is: noem het genre/stijl en/of de sfeer of energie.
        - Baseer stijl- en sfeerwoorden UITSLUITEND op het gemeten sonische profiel hierboven. Beweer GEEN kenmerken (akoestisch, dansbaar, rustig, …) die er niet in staan.
        - Sluit aan op het thema. Vermijd vage woordgrappen die het genre niet verraden.
        - Gebruik UITSLUITEND bestaande, correct gespelde Nederlandse woorden (Engelse genrenamen mogen). Verzin GEEN woorden.
        - Kort en krachtig: MAX 45 tekens, het liefst korter.

        Eisen voor "description":
        - 1 à 2 korte zinnen, vlot en correct Nederlands. Beschrijf de stijl/sfeer en noem een paar kenmerkende artiesten of het genre. Verzin geen woorden.
        """

        let config = LLMConfigStore.load()

        func attempt(_ prompt: String) async -> (title: String, description: String)? {
            let raw: String
            do {
                raw = try await LLMClient.shared.complete(system: system, user: prompt, config: config,
                                                          jsonMode: true, temperature: 0.35)
            } catch {
                Log.warning("Custom radio-titel mislukt voor '\(named)': \(error.localizedDescription) — tijdelijke standaardtitel", category: .network)
                return nil
            }
            let meta = parseTitleJSON(raw, fallbackTitle: fallback.title, fallbackDesc: fallback.description)
            guard meta.title != fallback.title else { return nil }
            return meta
        }

        guard let meta = await attempt(user) else { return nil }
        guard let stats else { return meta }
        let bad = TitleGrounding.violations(title: meta.title, description: meta.description,
                                            stats: stats, calibration: calibration)
        guard !bad.isEmpty else { return meta }
        let corrective = user + "\n\nLET OP — je eerdere titel/beschrijving bevatte claims die de metingen tegenspreken: \(bad.joined(separator: "; ")). Maak een nieuwe titel EN beschrijving ZONDER deze woorden, trouw aan het gemeten profiel."
        guard let retry = await attempt(corrective),
              TitleGrounding.violations(title: retry.title, description: retry.description,
                                        stats: stats, calibration: calibration).isEmpty else {
            return nil
        }
        return retry
    }

    /// A short NL description for the Qobuz playlist, built from the facets (no LLM).
    nonisolated static func customRadioDescription(_ cfg: RadioConfig) -> String {
        var parts: [String] = []
        if !cfg.artists.isEmpty { parts.append(cfg.artists.prefix(3).joined(separator: ", ")) }
        if !cfg.genres.isEmpty { parts.append(cfg.genres.prefix(3).map { $0.capitalized }.joined(separator: ", ")) }
        if !cfg.moods.isEmpty { parts.append(cfg.moods.prefix(3).map { moodLabel($0) }.joined(separator: ", ")) }
        if !cfg.activities.isEmpty {
            let labels = activityProfiles(calibration: nil).filter { cfg.activities.contains($0.key) }.map(\.label)
            parts.append(labels.joined(separator: ", "))
        }
        if !cfg.decades.isEmpty {
            parts.append(cfg.decades.sorted().map { $0 >= 2000 ? "Jaren \($0)" : "Jaren \($0 % 100)" }.joined(separator: ", "))
        }
        let facets = parts.filter { !$0.isEmpty }.joined(separator: " · ")
        return facets.isEmpty ? "Een sonische radio, samengesteld in RoonSage." : "Sonische radio · \(facets)"
    }

    // MARK: Materialisation (server-side, for Qobuz)

    /// Build the final tracklist for a custom config, reusing the artist-radio
    /// candidate builder + capping + flow-sequencing. Returns nil when the config
    /// has no facets, the library isn't analyzed, or nothing resolves.
    public func materializeCustomRadio(_ cfg: RadioConfig) async -> SonicRadioPlaylist? {
        guard cfg.hasFacets, let db = database else { return nil }
        let lib = await radioLibrary()
        guard !lib.isEmpty else { return nil }
        let disliked = radioDislikedMatchKeys
        let liked    = likedMatchKeys
        let known    = await knownArtistKeys(lib: lib)
        let hardBan  = radioHardBanDisliked
        let index    = await activeIndex(db)
        let taste    = await personalTasteVector(lib: lib, index: index)
        let genres   = (try? await db.genresByTrackID()) ?? [:]
        let years    = cfg.decades.isEmpty ? [:] : ((try? await db.yearByMatchKey()) ?? [:])
        let byId     = Dictionary(lib.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let stamp    = Self.dayStamp()
        let calibration = await Task.detached { TitleGrounding.Calibration.compute(library: lib) }.value
        let daySeed  = "\(stamp)|\(cfg.radioID)"

        let seedIds = Self.resolveCustomSeeds(cfg: cfg, lib: lib, genres: genres, years: years,
                                              calibration: calibration, disliked: disliked, daySeed: daySeed)
        guard !seedIds.isEmpty else { return nil }
        let gate = Self.customGate(cfg: cfg, genres: genres, years: years, calibration: calibration)
        let pool = await Task.detached {
            Self.buildPlaylistCandidates(
                seedIds: seedIds, lib: lib, index: index, genres: genres, disliked: disliked,
                daySeed: daySeed, limit: Self.artistRadioPoolLimit,
                likedKeys: liked, knownArtists: known, adventurousness: cfg.adventurousness,
                hardBan: hardBan, tasteVector: taste, relatedArtists: [:], gate: gate)
        }.value
        guard !pool.isEmpty else { return nil }

        let target = max(2, cfg.targetCount)
        let capped = Self.capForPlaylist(
            pool, seedArtist: "",
            minTracks: min(target, Self.artistRadioMinTracks),
            maxTracks: target,
            maxPerArtist: Self.artistRadioMaxPerArtist,
            seedCap: Self.artistRadioMaxPerArtist)
        guard capped.count >= 2 else { return nil }

        let tracks: [TrackRecord]
        if index != nil {
            let sts = capped.compactMap { byId[$0.id] }
            if sts.count == capped.count {
                tracks = RadioSequencer.order(sts, arc: .peak).map {
                    TrackRecord(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album)
                }
            } else { tracks = capped }
        } else { tracks = capped }

        var img: String? = nil
        for t in tracks { if let k = byId[t.id]?.imageKey, !k.isEmpty { img = k; break } }

        // AI title + description — same grounding machinery as the AI radios,
        // cached under the "custom:<id>" radio id (rename-in-place on drift via the
        // stored Qobuz id). A still-fresh title is reused without an LLM call.
        let sonics = tracks.compactMap { byId[$0.id] }
        let profile = Self.sonicProfileSummary(sonics, includeAttributes: radioAttributesEnabled,
                                               calibration: calibration)
        let radio = SonicRadio(id: cfg.radioID, artist: cfg.name, imageKey: img,
                               trackCount: tracks.count, seedIds: seedIds)
        let plan = titlePlan(for: radio, fallback: Self.customFallbackMeta(cfg: cfg),
                             sample: tracks, sonics: sonics)
        var generated: (title: String, description: String)?
        if !plan.fullyFresh {
            await LLMClient.shared.warmUp(config: LLMConfigStore.load())
            let stats = sonics.isEmpty ? nil : TitleGrounding.SelectionStats.compute(sonics)
            generated = await Self.generateCustomAIMeta(cfg: cfg, sample: tracks, profile: profile,
                                                        stats: stats, calibration: calibration)
        }
        let meta = resolveTitle(plan: plan, generated: generated)
        return SonicRadioPlaylist(
            id: cfg.radioID, artist: cfg.name, title: meta.title,
            description: meta.description, imageKey: img,
            tracks: tracks, qobuzPlaylistID: cfg.qobuzPlaylistID)
    }

    // MARK: Qobuz sync (server build only)
    //
    // Custom radios share the AI radios' Qobuz namespace ("RoonSage · <AI-titel>")
    // so they're truly indistinguishable. Two independent orphan-reconcilers on one
    // namespace would delete each other's playlists, so custom radios DON'T run
    // their own reconcile: instead `customRadioQobuzKeep()` folds the enabled ones
    // into EVERY AI reconcile's keep-set (see reconcileQobuzRadios). One namespace,
    // one keep-set, no fighting.

    /// The names + Qobuz ids of the custom radios that must survive any
    /// "RoonSage · " reconcile: every enabled, sync-on config (name from its cached
    /// AI title, or the fallback) plus its stored Qobuz id. Folded into both
    /// `reconcileQobuzRadios` variants so neither system prunes the other.
    func customRadioQobuzKeep() async -> (names: Set<String>, ids: Set<String>) {
        guard let db = database else { return ([], []) }
        let configs = (try? await db.listRadioConfigs()) ?? []
        var names = Set<String>(), ids = Set<String>()
        for cfg in configs where cfg.enabled && cfg.syncToQobuz {
            let title = Self.cachedRadioTitle(cfg.radioID) ?? Self.customFallbackMeta(cfg: cfg).title
            names.insert(Self.qobuzPlaylistName(for: title))
            if let qid = cfg.qobuzPlaylistID { ids.insert(qid) }
        }
        return (names, ids)
    }

    /// Mirror every enabled, sync-on custom radio to a stable Qobuz playlist under
    /// the SHARED "RoonSage · " namespace (find-or-create by name, rename-in-place
    /// via the stored id). No reconcile here — the shared AI reconcile prunes ours
    /// too (it keeps `customRadioQobuzKeep()`). Returns the number synced.
    @discardableResult
    public func syncCustomRadiosToQobuz() async -> Int {
        guard let email = KeychainStore.load(key: "qobuz_email"), !email.isEmpty,
              let pw = KeychainStore.load(key: "qobuz_password"), !pw.isEmpty else { return 0 }
        guard let db = database else { return 0 }
        let configs = (try? await db.listRadioConfigs()) ?? []
        let active = configs.filter { $0.enabled && $0.syncToQobuz }

        var keptIDs = Set<String>()
        var synced = 0
        for cfg in active {
            guard let pl = await materializeCustomRadio(cfg) else { continue }
            // Same naming as the AI radios: "RoonSage · <AI-titel>". Rename-in-place
            // via the stored id keeps the same Qobuz playlist when the title drifts.
            let name = Self.qobuzPlaylistName(for: pl.title)
            let pairs = pl.tracks.map { (title: $0.title, artist: $0.artist, album: $0.album) }
            if let result = await QobuzClient.shared.syncPlaylist(
                name: name, description: pl.description, tracks: pairs, email: email, password: pw,
                knownPlaylistID: cfg.qobuzPlaylistID) {
                try? await db.setRadioConfigQobuzID(id: cfg.id, result.playlistID)
                keptIDs.insert(result.playlistID)
                synced += 1
                Log.info("Custom radio gesynct naar Qobuz: '\(name)' (\(result.matched)/\(result.total) tracks)", category: .network)
            } else if let qid = cfg.qobuzPlaylistID {
                keptIDs.insert(qid)   // shrink-guard kept it intact → still live
            }
        }

        // Forget the Qobuz id of any config whose playlist is no longer kept (disabled
        // or sync toggled off) so the shared reconcile can prune it and a re-enable
        // creates a fresh playlist instead of updating a deleted one.
        for cfg in configs where cfg.qobuzPlaylistID != nil && !keptIDs.contains(cfg.qobuzPlaylistID!) {
            try? await db.setRadioConfigQobuzID(id: cfg.id, nil)
        }
        return synced
    }

    // MARK: Facet options (for the editor pickers)

    /// One selectable facet value. `key` is what's stored on the config; `label`
    /// (and optional `subtitle`) is what the editor shows.
    public struct FacetOption: Identifiable, Sendable, Hashable {
        public let key: String
        public let label: String
        public let subtitle: String?
        public var id: String { key }
        public init(key: String, label: String, subtitle: String? = nil) {
            self.key = key; self.label = label; self.subtitle = subtitle
        }
    }

    /// The pickable options for each facet, sourced from the analyzed library +
    /// the fixed mood/activity vocabularies. Works on client apps too (artists +
    /// genres come from the imported library; moods/activities are static).
    public struct RadioFacetOptions: Sendable {
        public var artists: [String]          // display names (stored as-is)
        public var tracks: [FacetOption]      // key = match_key
        public var genres: [FacetOption]      // key = lowercased genre
        public var moods: [FacetOption]       // key = CLAP mood key
        public var activities: [FacetOption]  // key = activity profile key
        public var decades: [Int]
        /// Liked + most-played artists, relevance-ordered — pinned above the full
        /// A-Z list in the seed pickers so favourites aren't buried in a huge library.
        public var featuredArtists: [String]
        /// Liked + most-played tracks, relevance-ordered (same purpose).
        public var featuredTracks: [FacetOption]
        public init(artists: [String], tracks: [FacetOption], genres: [FacetOption],
                    moods: [FacetOption], activities: [FacetOption], decades: [Int],
                    featuredArtists: [String] = [], featuredTracks: [FacetOption] = []) {
            self.artists = artists; self.tracks = tracks; self.genres = genres
            self.moods = moods; self.activities = activities; self.decades = decades
            self.featuredArtists = featuredArtists; self.featuredTracks = featuredTracks
        }
    }

    /// Gather the facet options once for the editor. Cheap enough to call on-appear.
    public func radioFacetOptions() async -> RadioFacetOptions {
        let lib = await radioLibrary()

        var artistSet = Set<String>()
        var tracks: [FacetOption] = []
        var seenTracks = Set<String>()
        var trackByKey: [String: FacetOption] = [:]
        var artistDisplay: [String: String] = [:]   // lowercased → library display name
        for t in lib {
            if let a = t.artist, !a.isEmpty {
                artistSet.insert(a)
                if artistDisplay[a.lowercased()] == nil { artistDisplay[a.lowercased()] = a }
            }
            let mk = t.matchKey
            if !mk.isEmpty, seenTracks.insert(mk).inserted {
                let opt = FacetOption(key: mk, label: t.title, subtitle: t.artist)
                tracks.append(opt)
                trackByKey[mk] = opt
            }
        }
        let artists = artistSet.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        tracks.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }

        // Favourites-first: liked, then most-played, deduped. Resolved to the
        // library's display name / track option so the pickers can pin them.
        let (likedArtists, _) = await feedbackArtistHints()
        let topArtists = ((try? await database?.topArtistsListened(limit: 40)) ?? []).map(\.artist)
        var featuredArtists: [String] = []
        var seenArtist = Set<String>()
        for a in likedArtists + topArtists {
            let display = artistDisplay[a.lowercased()] ?? a
            guard artistSet.contains(display), seenArtist.insert(display.lowercased()).inserted else { continue }
            featuredArtists.append(display)
            if featuredArtists.count >= 30 { break }
        }
        let likedTrackKeys = Array(likedMatchKeys)
        let topTrackKeys = (await playStats()).sorted { $0.count > $1.count }.map(\.matchKey)
        var featuredTracks: [FacetOption] = []
        var seenTrack = Set<String>()
        for mk in likedTrackKeys + topTrackKeys {
            guard let opt = trackByKey[mk], seenTrack.insert(mk).inserted else { continue }
            featuredTracks.append(opt)
            if featuredTracks.count >= 30 { break }
        }

        var genres: [FacetOption] = []
        if let db = database, let map = try? await db.genresByTrackID() {
            var counts: [String: Int] = [:]
            var labelFor: [String: String] = [:]
            for (_, gs) in map {
                for raw in gs {
                    let key = raw.lowercased().trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { continue }
                    counts[key, default: 0] += 1
                    if labelFor[key] == nil { labelFor[key] = raw }
                }
            }
            genres = counts.sorted { $0.value > $1.value }.map {
                FacetOption(key: $0.key, label: labelFor[$0.key] ?? $0.key.capitalized)
            }
        }

        let moods = RoonClient.knownMoodKeys.map { FacetOption(key: $0, label: RoonClient.moodLabel($0)) }
        let activities = RoonClient.activityProfiles(calibration: nil).map { FacetOption(key: $0.key, label: $0.label) }

        var decadeSet = Set<Int>()
        if let db = database, let years = try? await db.yearByMatchKey() {
            for (_, y) in years where RoonClient.isPlausibleYear(y) { decadeSet.insert((y / 10) * 10) }
        }
        let decades = decadeSet.sorted(by: >)

        return RadioFacetOptions(artists: artists, tracks: tracks, genres: genres,
                                 moods: moods, activities: activities, decades: decades,
                                 featuredArtists: featuredArtists, featuredTracks: featuredTracks)
    }

    // MARK: Playback (all builds)

    /// Start an endless station from a custom config. Resolves the seeds, then hands
    /// off to the shared `startRadio` — whose top-up re-applies the combined gate via
    /// `candidateGate(for:)`, keeping the station true to the config's definition.
    public func startCustomRadio(_ cfg: RadioConfig, zoneID: String) async {
        guard cfg.hasFacets else {
            reportError("Deze radio heeft nog geen bron — voeg een artiest, nummer, genre, sfeer of activiteit toe.")
            return
        }
        guard let db = database else { reportError("Radio mislukt — geen bibliotheek beschikbaar."); return }
        let lib = await radioLibrary()
        guard !lib.isEmpty else { reportError("Radio mislukt — nog geen geanalyseerde bibliotheek beschikbaar."); return }
        let disliked = radioDislikedMatchKeys
        let genres = (try? await db.genresByTrackID()) ?? [:]
        let years  = cfg.decades.isEmpty ? [:] : ((try? await db.yearByMatchKey()) ?? [:])
        let calibration: TitleGrounding.Calibration? = cfg.activities.isEmpty
            ? nil : await Task.detached { TitleGrounding.Calibration.compute(library: lib) }.value
        let daySeed = "\(Self.dayStamp())|\(cfg.radioID)"
        let seedIds = Self.resolveCustomSeeds(cfg: cfg, lib: lib, genres: genres, years: years,
                                              calibration: calibration, disliked: disliked, daySeed: daySeed)
        guard !seedIds.isEmpty else {
            reportError("Geen passende tracks gevonden voor deze radio — verruim de selectie of analyseer meer muziek.")
            return
        }
        var img: String? = nil
        let byId = Dictionary(lib.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in seedIds { if let k = byId[id]?.imageKey, !k.isEmpty { img = k; break } }
        let radio = SonicRadio(id: cfg.radioID, artist: cfg.name, imageKey: img,
                               trackCount: seedIds.count, seedIds: seedIds)
        await startRadio(radio, zoneID: zoneID)
    }
}
