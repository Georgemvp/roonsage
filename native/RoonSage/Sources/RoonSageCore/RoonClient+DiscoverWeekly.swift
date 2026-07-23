import AudioAnalysis
import Foundation

// MARK: - "Ontdek Wekelijks" — the library-first weekly discovery playlist
//
// A fresh, automatically-generated playlist that refreshes itself weekly (the
// Discover Weekly idea, à la Explo) but LIBRARY-FIRST and fully local: tracks are
// picked by CLAP-embedding similarity to the user's most-played tracks (reusing
// `RadioEngine`/`RadioSequencer`/`TasteVector`/`VectorIndex`), then everything
// heard in the recent listening history is excluded so it's genuinely discovery.
// Optionally enriched with ListenBrainz recommendations — but only tracks that
// actually exist in the library or on Qobuz (the rest are skipped), and anything
// not owned is labelled "nog niet in je bibliotheek".
//
// Runs as a scheduled job on the always-on server build (`.direct`), alongside the
// 15-minute Last.fm sync. Generated at most once per configurable interval and
// idempotent per ISO week. Stored in GRDB (server-of-record) so it survives a
// resync and is replayable; thin clients pull it over /discover-weekly.

// MARK: Model (shared across the DB layer, the HTTP endpoint and the UI)

/// One track in the weekly playlist. `notInLibrary` marks a Qobuz/ListenBrainz
/// enrichment pick so the UI can flag it "nog niet in je bibliotheek". `id` is the
/// Roon item_key for library tracks or a synthetic `qobuz_search::` key otherwise;
/// playback (`curateTracks`) re-resolves both.
public struct DiscoverWeeklyTrack: Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var notInLibrary: Bool
    // Artwork for the tracklist row. Optional so a weekly playlist cached before
    // this field existed still decodes (synthesized Codable reads a missing
    // optional key as nil); such rows just show the placeholder until the next
    // refresh regenerates the playlist with per-track art.
    public var imageKey: String?

    public init(id: String, title: String, artist: String?, album: String?, notInLibrary: Bool, imageKey: String? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.album = album
        self.notInLibrary = notInLibrary; self.imageKey = imageKey
    }

    /// A `TrackRecord` for playback / resolution.
    public var record: TrackRecord { TrackRecord(id: id, title: title, artist: artist, album: album, imageKey: imageKey) }
}

/// A generated weekly discovery playlist (one per ISO week).
public struct DiscoverWeeklyPlaylist: Codable, Sendable, Identifiable {
    public var weekKey: String          // ISO week, e.g. "2026-W27" (row key + label)
    public var generatedAt: String      // ISO8601 build timestamp
    public var title: String            // AI-generated Dutch title
    public var description: String      // AI-generated Dutch description
    public var imageKey: String?        // artwork from a representative track
    public var seedMatchKeys: [String]  // the most-played tracks it was seeded on
    public var tracks: [DiscoverWeeklyTrack]

    public var id: String { weekKey }
    public var trackRecords: [TrackRecord] { tracks.map(\.record) }
    public var libraryCount: Int { tracks.filter { !$0.notInLibrary }.count }
    public var discoveryCount: Int { tracks.filter { $0.notInLibrary }.count }

    /// Lower-cased album names this weekly already surfaces — so the "Herontdek"
    /// shelves can avoid re-showing the same owned albums (cross-feature de-dup).
    public var albumKeysSurfaced: Set<String> {
        Set(tracks.compactMap { $0.album?.lowercased() }.filter { !$0.isEmpty })
    }
    /// Lower-cased "title|artist" identities this weekly already surfaces.
    public var trackKeysSurfaced: Set<String> {
        Set(tracks.map { "\($0.title.lowercased())|\(($0.artist ?? "").lowercased())" })
    }

    public init(weekKey: String, generatedAt: String, title: String, description: String,
                imageKey: String?, seedMatchKeys: [String], tracks: [DiscoverWeeklyTrack]) {
        self.weekKey = weekKey; self.generatedAt = generatedAt; self.title = title
        self.description = description; self.imageKey = imageKey
        self.seedMatchKeys = seedMatchKeys; self.tracks = tracks
    }
}

@MainActor
extension RoonClient {

    // MARK: Tuning

    /// How many most-played tracks anchor the CLAP similarity search.
    nonisolated static let discoverWeeklySeedLimit = 40
    /// Hourly "is a new weekly due?" check on the server build.
    nonisolated static let discoverWeeklyCheckInterval: UInt64 = 60 * 60 * 1_000_000_000

    // MARK: Settings (UserDefaults; authoritative on the server build)

    /// Master switch for the weekly job + UI. Default on.
    public var discoverWeeklyEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: "discover_weekly_enabled") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "discover_weekly_enabled") }
    }
    /// Minimum days between automatic regenerations. Default 7 (weekly).
    public var discoverWeeklyIntervalDays: Int {
        get { let v = UserDefaults.standard.integer(forKey: "discover_weekly_interval_days"); return v > 0 ? v : 7 }
        set { UserDefaults.standard.set(max(1, newValue), forKey: "discover_weekly_interval_days") }
    }
    /// Target playlist length. Default 30.
    public var discoverWeeklyTrackCount: Int {
        get { let v = UserDefaults.standard.integer(forKey: "discover_weekly_track_count"); return v > 0 ? v : 30 }
        set { UserDefaults.standard.set(min(100, max(5, newValue)), forKey: "discover_weekly_track_count") }
    }
    /// Tracks played within this many days are excluded (that's what makes it
    /// discovery). Default 30.
    public var discoverWeeklyExclusionDays: Int {
        get { let v = UserDefaults.standard.integer(forKey: "discover_weekly_exclusion_days"); return v > 0 ? v : 30 }
        set { UserDefaults.standard.set(max(0, newValue), forKey: "discover_weekly_exclusion_days") }
    }
    /// Blend in ListenBrainz recommendations (library/Qobuz-existing only). Default on.
    public var discoverWeeklyListenBrainzEnrich: Bool {
        get { (UserDefaults.standard.object(forKey: "discover_weekly_lb_enrich") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "discover_weekly_lb_enrich") }
    }

    // MARK: Read (server = DB, client = HTTP)

    /// The current weekly playlist, or nil if none has been generated yet.
    public func discoverWeekly() async -> DiscoverWeeklyPlaylist? {
        if isRemote, let base = remoteBaseURL {
            return await fetchDiscoverWeeklyFromServer(base: base)
        }
        if let cached = cachedDiscoverWeekly { return cached }
        let latest = (try? await database?.latestDiscoverWeekly()) ?? nil
        cachedDiscoverWeekly = latest
        return latest
    }

    /// Like `discoverWeekly()` but surfacing fetch failures so the view can show a
    /// "server onbereikbaar · opnieuw proberen" state instead of the (misleading)
    /// "nog geen wekelijkse playlist" empty state. A `null` body (none built yet)
    /// is a legitimate nil, not an error.
    public func discoverWeeklyChecked() async throws -> DiscoverWeeklyPlaylist? {
        if isRemote {
            return try await shareGETChecked("/discover-weekly", as: DiscoverWeeklyPlaylist?.self)
        }
        if let cached = cachedDiscoverWeekly { return cached }
        let latest = (try? await database?.latestDiscoverWeekly()) ?? nil
        cachedDiscoverWeekly = latest
        return latest
    }

    /// Manual "Ververs nu" surfacing transport/server failures. Local build returns
    /// nil (nothing to build from) rather than throwing — that's an empty, not error.
    @discardableResult
    public func refreshDiscoverWeeklyChecked() async throws -> DiscoverWeeklyPlaylist? {
        if isRemote {
            guard let base = remoteBaseURL, let url = URL(string: "\(base)/discover-weekly/refresh") else {
                throw DiscoveryFetchError.notConnected
            }
            var req = URLRequest(url: url); req.httpMethod = "POST"
            req.timeoutInterval = 180   // building runs the LLM + Qobuz lookups
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")  // server CSRF guard rejects non-JSON POSTs
            authorizeShareRequest(&req)
            let data: Data, resp: URLResponse
            do { (data, resp) = try await URLSession.shared.data(for: req) }
            catch { throw DiscoveryFetchError.transport(error.localizedDescription) }
            guard let http = resp as? HTTPURLResponse else { throw DiscoveryFetchError.decode }
            guard http.statusCode == 200 else { throw DiscoveryFetchError.server(http.statusCode) }
            return try? JSONDecoder().decode(DiscoverWeeklyPlaylist.self, from: data)
        }
        return await buildDiscoverWeekly(force: true)
    }

    /// JSON for the share server's `GET /discover-weekly` (latest built playlist, or
    /// `null` when none exists yet — the client then offers "Ververs nu").
    public func discoverWeeklyData() async -> Data {
        guard let pl = await discoverWeekly() else { return Data("null".utf8) }
        return (try? JSONEncoder().encode(pl)) ?? Data("null".utf8)
    }

    /// Manual "Ververs nu": rebuild the current week now (server) or ask the server
    /// to (client). Returns the fresh playlist.
    @discardableResult
    public func refreshDiscoverWeekly() async -> DiscoverWeeklyPlaylist? {
        if isRemote, let base = remoteBaseURL {
            return await postDiscoverWeeklyRefresh(base: base)
        }
        return await buildDiscoverWeekly(force: true)
    }

    // MARK: Scheduler (server build)

    /// Whether a new weekly should be generated: no interval has elapsed since the
    /// last build. Pure + testable.
    nonisolated static func discoverWeeklyDue(current: DiscoverWeeklyPlaylist?, intervalDays: Int, now: Date = Date()) -> Bool {
        guard let current else { return true }
        guard let gen = ISO8601DateFormatter().date(from: current.generatedAt) else { return true }
        return now.timeIntervalSince(gen) >= Double(max(1, intervalDays)) * 86_400
    }

    /// Build a fresh weekly only if one is due (interval elapsed). Idempotent.
    public func buildDiscoverWeeklyIfDue() async {
        guard controlMode == .direct, discoverWeeklyEnabled else { return }
        var current = cachedDiscoverWeekly
        if current == nil { current = (try? await database?.latestDiscoverWeekly()) ?? nil }
        cachedDiscoverWeekly = current
        guard Self.discoverWeeklyDue(current: current, intervalDays: discoverWeeklyIntervalDays) else { return }
        _ = await buildDiscoverWeekly(force: false)
    }

    /// Start the hourly "is a new weekly due?" watch. No-op unless this is the
    /// always-on server build (`.direct`); client apps read/refresh over HTTP.
    public func startDiscoverWeeklySchedule() {
        guard controlMode == .direct, discoverWeeklyTask == nil else { return }
        discoverWeeklyTask = Task { [weak self] in
            // Grace so the library + features finish loading before the first build.
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                if self.discoverWeeklyEnabled {
                    await self.buildDiscoverWeeklyIfDue()
                }
                try? await Task.sleep(nanoseconds: Self.discoverWeeklyCheckInterval)
            }
        }
        Log.info("Ontdek Wekelijks scheduler gestart (elk uur gecontroleerd; max 1× per interval)", category: .roon)
    }

    public func stopDiscoverWeeklySchedule() {
        discoverWeeklyTask?.cancel()
        discoverWeeklyTask = nil
    }

    // MARK: Build (server build only)

    /// Generate (or regenerate) the weekly discovery playlist and persist it.
    /// Returns nil when there's nothing to build (no analyzed library / embeddings /
    /// history, or the selection was empty after exclusion). `force` is accepted for
    /// symmetry with the scheduler; the current week's row is simply upserted.
    @discardableResult
    public func buildDiscoverWeekly(force: Bool) async -> DiscoverWeeklyPlaylist? {
        if isRemote, let base = remoteBaseURL {
            return await fetchDiscoverWeeklyFromServer(base: base)
        }
        guard let db = database else { return nil }

        let lib = await radioLibrary()
        guard !lib.isEmpty else {
            Log.warning("Ontdek Wekelijks: 0 geanalyseerde tracks — analyseer eerst je bibliotheek.", category: .roon)
            return nil
        }
        guard let index = await activeIndex(db) else {
            Log.warning("Ontdek Wekelijks: geen CLAP-embeddings — kan geen similariteit berekenen.", category: .roon)
            return nil
        }
        let playStats = (try? await db.playStatsByMatchKey()) ?? []
        guard !playStats.isEmpty else {
            Log.warning("Ontdek Wekelijks: geen luistergeschiedenis — nog geen seeds.", category: .roon)
            return nil
        }

        let byMatchKey = Dictionary(lib.map { ($0.matchKey, $0) }, uniquingKeysWith: { a, _ in a })
        let options = DiscoverWeekly.Options(
            trackCount: discoverWeeklyTrackCount,
            adventurousness: min(1, radioAdventurousness + 0.2),
            exclusionDays: discoverWeeklyExclusionDays,
            maxPerArtist: 2)

        // The ISO week both salts the seed rotation (so a different loved set anchors
        // each week) and salts the ranking jitter below.
        let weekKey = DigestSelection.weekKey(for: Date())
        let seeds = DiscoverWeekly.selectSeeds(
            playStats: playStats, byMatchKey: byMatchKey,
            limit: Self.discoverWeeklySeedLimit, salt: weekKey)
        guard !seeds.isEmpty else {
            Log.warning("Ontdek Wekelijks: geen seeds gevonden onder de geanalyseerde tracks.", category: .roon)
            return nil
        }
        let recentKeys = DiscoverWeekly.recentlyPlayedKeys(
            playStats: playStats, withinDays: options.exclusionDays)

        let disliked = dislikedMatchKeys
        let liked = likedMatchKeys
        let known = await knownArtistKeys(lib: lib)
        let taste = await personalTasteVector(lib: lib, index: index)

        // The heavy ranking runs off the main actor.
        let ordered = await Task.detached {
            DiscoverWeekly.plan(
                seeds: seeds, library: lib, index: index,
                recentlyPlayedKeys: recentKeys, disliked: disliked, likedKeys: liked,
                knownArtists: known, tasteVector: taste, options: options, salt: weekKey)
        }.value
        guard !ordered.isEmpty else {
            Log.warning("Ontdek Wekelijks: selectie leeg na exclusie (alles recent gespeeld?).", category: .roon)
            return nil
        }

        var tracks = ordered.map {
            DiscoverWeeklyTrack(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album,
                                notInLibrary: false, imageKey: $0.imageKey)
        }

        // ListenBrainz enrichment (library/Qobuz-existing only, labelled).
        if discoverWeeklyListenBrainzEnrich {
            let existing = Set(tracks.map { Self.dwDedupKey($0.title, $0.artist) })
            // Cross-feature de-dup: the "Nieuw voor jou" pipeline already surfaces new
            // artists from the *same* ListenBrainz account. Exclude its latest picks so
            // the weekly's new tail doesn't echo the feed (the overlap the whole audit
            // was about). Owned rediscovery is unaffected — this only gates new tracks.
            let feedArtists = Set(
                ((try? await db.latestRecommendationItems(limit: 200)) ?? [])
                    .map { $0.artist.lowercased() }
                    .filter { !$0.isEmpty })
            let enrich = await listenBrainzEnrichment(
                excludeDedup: existing, excludeNewArtists: feedArtists, recentKeys: recentKeys,
                limit: max(1, discoverWeeklyTrackCount / 5))
            if !enrich.isEmpty {
                tracks.append(contentsOf: enrich)
                Log.info("Ontdek Wekelijks: \(enrich.count) ListenBrainz-verrijking(en) toegevoegd", category: .network)
            }
        }

        let profile = Self.sonicProfileSummary(ordered, includeAttributes: radioAttributesEnabled)
        let meta = await discoverWeeklyMeta(sample: ordered, profile: profile)
        let imageKey = ordered.first(where: { $0.imageKey?.isEmpty == false })?.imageKey

        let pl = DiscoverWeeklyPlaylist(
            weekKey: weekKey, generatedAt: Self.dwISONow(),
            title: meta.title, description: meta.description, imageKey: imageKey,
            seedMatchKeys: seeds.map(\.matchKey), tracks: tracks)

        try? await db.upsertDiscoverWeekly(pl)
        cachedDiscoverWeekly = pl
        Log.info("Ontdek Wekelijks gebouwd (\(weekKey)): \(pl.tracks.count) tracks (\(pl.discoveryCount) buiten bibliotheek)", category: .roon)
        return pl
    }

    // MARK: ListenBrainz enrichment

    /// Pull tracks from the user's ListenBrainz "created for you" playlists (Weekly
    /// Discovery / Exploration / Jams) and keep only those that exist in the library
    /// or resolve on Qobuz — anything else is skipped (library-first). Owned tracks
    /// recently played are dropped too (still discovery). Returns at most `limit`.
    private func listenBrainzEnrichment(
        excludeDedup: Set<String>, excludeNewArtists: Set<String> = [],
        recentKeys: Set<String>, limit: Int
    ) async -> [DiscoverWeeklyTrack] {
        guard let token = KeychainStore.load(key: "listenbrainz_token"), !token.isEmpty else { return [] }
        guard let user = await ListenBrainzClient.shared.resolveUsername(token: token), !user.isEmpty else { return [] }

        let refs = await ListenBrainzClient.shared.userPlaylists(username: user, token: token, includeCreatedFor: true)
        guard !refs.isEmpty else { return [] }
        // Prefer LB's discovery-flavoured generated playlists.
        let preferred = refs.filter { r in
            let t = r.title.lowercased()
            return t.contains("discovery") || t.contains("exploration") || t.contains("jams") || t.contains("weekly")
        }
        let chosen = (preferred.isEmpty ? Array(refs.prefix(2)) : preferred).prefix(3)

        var candidates: [(title: String, artist: String?, album: String?)] = []
        for ref in chosen {
            for t in await ListenBrainzClient.shared.playlistTracks(mbid: ref.mbid, token: token) {
                candidates.append((t.title, t.artist, t.album))
            }
            if candidates.count >= 80 { break }
        }
        guard !candidates.isEmpty else { return [] }

        // One-pass in-library resolution by title+artist (preserves order → aligns).
        let probes = candidates.map { TrackRecord(id: "lb", title: $0.title, artist: $0.artist) }
        let matches = (try? await database?.resolveCurrentTracksAligned(probes)) ?? []

        var out: [DiscoverWeeklyTrack] = []
        var seen = excludeDedup
        var qobuzAttempts = 0
        let maxQobuzAttempts = max(4, limit * 3)
        for (i, cand) in candidates.enumerated() {
            if out.count >= limit { break }
            let dedup = Self.dwDedupKey(cand.title, cand.artist)
            guard seen.insert(dedup).inserted else { continue }

            // 1) Already in the library?
            if i < matches.count, let m = matches[i] {
                if let mk = m.matchKey, recentKeys.contains(mk) { continue }  // recently played → not discovery
                out.append(DiscoverWeeklyTrack(id: m.id, title: m.title, artist: m.artist,
                                               album: m.album, notInLibrary: false, imageKey: m.imageKey))
                continue
            }
            // 2) Not owned — does it exist on Qobuz UNDER THE SAME title+artist?
            //    Library-first: accept only a hit whose normalised identity matches
            //    the candidate. Taking `.first` blindly could attach an UNRELATED
            //    song's id to the candidate's title/artist → the wrong track plays.
            //    Cross-feature de-dup: skip new tracks whose artist the "Nieuw voor
            //    jou" feed already surfaces, so the two features don't overlap.
            if let a = cand.artist, excludeNewArtists.contains(a.lowercased()) { continue }
            guard qobuzAttempts < maxQobuzAttempts else { continue }
            qobuzAttempts += 1
            let query = [cand.artist, cand.title].compactMap { $0 }.joined(separator: " ")
            let wantKey = TrackIdentity.matchKey(artist: cand.artist, album: nil, title: cand.title)
            if let q = await searchQobuz(query: query, limit: 3).first(where: {
                TrackIdentity.matchKey(artist: $0.artist, album: $0.album, title: $0.title) == wantKey
            }) {
                out.append(DiscoverWeeklyTrack(id: q.id, title: cand.title, artist: cand.artist,
                                               album: cand.album, notInLibrary: true, imageKey: q.imageKey))
            }
            // else: no confident Qobuz match → skip (library-first).
        }
        return out
    }

    // MARK: AI title + description

    /// Ask the configured LLM for a Dutch weekly title + description as strict JSON,
    /// steered by the sonic profile. Falls back to a fixed title/description when the
    /// LLM is unavailable (not cached — a later build retries).
    private func discoverWeeklyMeta(sample: [DatabaseManager.SonicTrack], profile: String) async -> (title: String, description: String) {
        let fallback = ("Ontdek Wekelijks",
                        "Een verse selectie uit je eigen bibliotheek — muziek die past bij wat je graag hoort maar de laatste tijd links liet liggen.")
        let examples = sample.prefix(8)
            .map { "• \($0.title) — \($0.artist ?? "onbekend")" }
            .joined(separator: "\n")

        let system = """
        Je bent een muziekredacteur die pakkende, INFORMATIEVE Nederlandse playlist-titels schrijft. \
        Antwoord UITSLUITEND met strikt geldige JSON, exact in de vorm \
        {"title": "...", "description": "..."}. Geen uitleg, geen markdown, geen codeblok.
        """
        let user = """
        Maak een titel en korte beschrijving voor een wekelijkse ONTDEK-playlist uit iemands eigen \
        bibliotheek: muziek die past bij hun smaak maar die ze recent niet hebben gespeeld — een \
        persoonlijke "Ontdek Wekelijks".

        Sonisch profiel van de selectie: \(profile.isEmpty ? "onbekend" : profile)
        Voorbeeldtracks:
        \(examples)

        Eisen voor "title":
        - Maak METEEN duidelijk dat het een verse, persoonlijke ontdek-selectie is, en verraad de sfeer/stijl.
        - Gebruik UITSLUITEND bestaande, correct gespelde Nederlandse woorden (Engelse genrenamen mogen).
        - Kort en krachtig: MAX 45 tekens.

        Eisen voor "description":
        - 1 à 2 korte zinnen, vlot Nederlands. Beschrijf de sfeer/stijl van de week. Verzin geen woorden.
        """

        let config = LLMConfigStore.load()
        guard let raw = try? await LLMClient.shared.complete(system: system, user: user, config: config) else {
            Log.warning("Ontdek Wekelijks: AI-titel mislukt — tijdelijke standaardtitel", category: .network)
            return fallback
        }
        return RoonClient.parseTitleJSON(raw, fallbackTitle: fallback.0, fallbackDesc: fallback.1)
    }

    // MARK: Remote fetch (client apps)

    private func fetchDiscoverWeeklyFromServer(base: String) async -> DiscoverWeeklyPlaylist? {
        guard let url = URL(string: "\(base)/discover-weekly") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(DiscoverWeeklyPlaylist.self, from: data)
    }

    private func postDiscoverWeeklyRefresh(base: String) async -> DiscoverWeeklyPlaylist? {
        guard let url = URL(string: "\(base)/discover-weekly/refresh") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180   // building runs the LLM + Qobuz lookups
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")  // server CSRF guard rejects non-JSON POSTs
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(DiscoverWeeklyPlaylist.self, from: data)
    }

    // MARK: Small helpers

    /// Normalised "artist|title" dedup key (collapses "(Remix)"/"(feat…)" versions).
    nonisolated static func dwDedupKey(_ title: String, _ artist: String?) -> String {
        "\((artist ?? "").lowercased())|\(titleDedupKey(title))"
    }

    nonisolated static func dwISONow() -> String { ISO8601DateFormatter().string(from: Date()) }
}
