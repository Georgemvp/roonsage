import Foundation

// MARK: - AI Artist Radios → Qobuz
//
// Builds ~6 artist-seeded stations (the same seeds as `dailyRadios()`), caps
// each to a 20–30 track playlist, gives every station an AI-generated Dutch
// title + description, and mirrors them to Qobuz as STABLE playlists that a
// refresh updates in place (find-or-create + replace) instead of duplicating.
//
// ## Stable identity (the one chosen key)
// The Qobuz **exact playlist name** — `"RoonSage · <AI-title>"` — is the find
// key. To keep that name stable across refreshes (the AI title is generated
// from the *current* selection, which changes every 3h) we generate the title
// ONCE per radio and cache it in UserDefaults keyed by the radio id
// (`artist:<lower>`). Every later refresh reuses the cached title, so the name —
// and therefore the playlist Qobuz resolves it to — stays put. The radio id is
// the anchor; the cached title is its stable human face. We also persist the
// resolved Qobuz playlist id for display/diagnostics.

extension RoonClient {

    // MARK: Tuning
    nonisolated static let artistRadioCount       = 6
    nonisolated static let artistRadioMinTracks   = 20
    nonisolated static let artistRadioMaxTracks   = 30
    /// Variety cap for non-seed artists (keeps the playlist from leaning on one
    /// neighbour).
    nonisolated static let artistRadioMaxPerArtist = 3
    /// Cap on the seed artist's own tracks — anchors the playlist without turning
    /// it into a single-artist mix; the rest are nearest sonic neighbours.
    nonisolated static let artistRadioSeedCap = 10
    /// Re-sync cadence on the always-on server build.
    nonisolated static let artistRadioRefreshInterval: UInt64 = 3 * 60 * 60 * 1_000_000_000

    // MARK: Model

    /// One AI artist radio prepared for (or already mirrored to) Qobuz.
    public struct SonicRadioPlaylist: Sendable, Identifiable {
        public let id: String          // == SonicRadio.id ("artist:<lower>") — the stable anchor
        public let artist: String      // seed artist (display name)
        public let title: String       // AI playlist title (cached, stable)
        public let description: String // AI playlist description (1–2 sentences, NL)
        public let imageKey: String?   // artwork from a representative track
        public let tracks: [TrackRecord]
        public var qobuzPlaylistID: String?   // set once mirrored / known

        /// The stable Qobuz playlist name derived from the AI title.
        public var qobuzName: String { RoonClient.qobuzPlaylistName(for: title) }
    }

    nonisolated static func qobuzPlaylistName(for title: String) -> String { "RoonSage · \(title)" }

    // MARK: Build

    /// Build the ~6 AI artist radios: same seeds as the daily stations, each
    /// capped to a 20–30 track playlist with an AI title + description. Pure
    /// read — does not touch Qobuz. Safe to call from either build (server or a
    /// client app rendering the cards).
    public func buildArtistRadioPlaylists() async -> [SonicRadioPlaylist] {
        guard let db = database else {
            Log.warning("Artiesten-radio's: geen database beschikbaar — overgeslagen", category: .roon)
            return []
        }
        let lib = await sonicCache.tracks(from: db)
        guard !lib.isEmpty else {
            Log.warning("Artiesten-radio's: 0 geanalyseerde tracks (audio-features). Sync eerst de features naar dit apparaat.", category: .roon)
            return []
        }
        let radios = Array(await dailyRadios().prefix(Self.artistRadioCount))
        guard !radios.isEmpty else {
            Log.warning("Artiesten-radio's: geen seed-artiesten — lege luistergeschiedenis of te weinig geanalyseerde tracks per artiest.", category: .roon)
            return []
        }
        let index = await activeIndex(db)
        // Roon genres per track, for genre-affinity ranking of the neighbours.
        let genres = (try? await db.genresByTrackID()) ?? [:]
        // id → analyzed track, so we can summarise the sonic profile (tags,
        // mood, energy, tempo) of the selection for the title prompt.
        let byId = Dictionary(lib.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var out: [SonicRadioPlaylist] = []
        for radio in radios {
            let seedIds = radio.seedIds
            let key = radio.id
            // Coherent, similarity-ordered candidates (nearest neighbours first),
            // NOT the endless radio's shuffled 250-pool.
            let pool = await Task.detached {
                Self.buildPlaylistCandidates(seedIds: seedIds, lib: lib, index: index, genres: genres)
            }.value
            guard !pool.isEmpty else { continue }

            let tracks = Self.capForPlaylist(
                pool, seedArtist: radio.artist,
                minTracks: Self.artistRadioMinTracks,
                maxTracks: Self.artistRadioMaxTracks,
                maxPerArtist: Self.artistRadioMaxPerArtist,
                seedCap: Self.artistRadioSeedCap)
            guard tracks.count >= 2 else { continue }

            let profile = Self.sonicProfileSummary(tracks.compactMap { byId[$0.id] })
            let meta = await aiTitleAndDescription(for: radio, sample: tracks, profile: profile)
            out.append(SonicRadioPlaylist(
                id: key, artist: radio.artist, title: meta.title, description: meta.description,
                imageKey: radio.imageKey, tracks: tracks,
                qobuzPlaylistID: UserDefaults.standard.string(forKey: Self.qobuzIDKey(key))))
        }
        Log.info("Artiesten-radio's gebouwd: \(out.count) playlists (van \(radios.count) seeds, \(lib.count) geanalyseerde tracks)", category: .roon)
        return out
    }

    /// Cap the (similarity-ordered) candidate pool to a playlist of
    /// `minTracks…maxTracks`, limiting non-seed artists to `maxPerArtist` and the
    /// seed artist to `seedCap` (so it's a radio, not a single-artist mix). If the
    /// cap leaves us short of `minTracks`, top up from what was skipped.
    nonisolated static func capForPlaylist(
        _ pool: [TrackRecord], seedArtist: String,
        minTracks: Int, maxTracks: Int, maxPerArtist: Int, seedCap: Int = .max
    ) -> [TrackRecord] {
        let seedKey = seedArtist.lowercased()
        var perArtist: [String: Int] = [:]
        var seenTitles = Set<String>()   // collapse "song", "song (Remix)", "song (feat…)"
        var picked: [TrackRecord] = []
        var skipped: [TrackRecord] = []
        for t in pool {
            if picked.count >= maxTracks { break }
            let a = (t.artist ?? "").lowercased()
            let titleKey = "\(a)|\(titleDedupKey(t.title))"
            if seenTitles.contains(titleKey) { continue }   // drop near-duplicate versions
            let cap = a == seedKey ? seedCap : maxPerArtist
            if perArtist[a, default: 0] < cap {
                perArtist[a, default: 0] += 1
                seenTitles.insert(titleKey)
                picked.append(t)
            } else {
                skipped.append(t)
            }
        }
        if picked.count < minTracks {
            for t in skipped {
                if picked.count >= min(minTracks, maxTracks) { break }
                let titleKey = "\((t.artist ?? "").lowercased())|\(titleDedupKey(t.title))"
                if seenTitles.insert(titleKey).inserted { picked.append(t) }
            }
        }
        return picked
    }

    /// Normalised title for dedup: lowercased, with bracketed/parenthesised
    /// qualifiers ("(feat…)", "(… Remix)", "[Album Version]") stripped, so the
    /// same song in several editions collapses to one entry.
    nonisolated static func titleDedupKey(_ title: String) -> String {
        var s = title.lowercased()
        s = s.replacingOccurrences(of: #"[\(\[\{].*?[\)\]\}]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Similarity-ordered candidate list for a coherent artist PLAYLIST (distinct
    /// from the endless radio's shuffled pool): the seed artist's own tracks first,
    /// then the nearest sonic neighbours in descending similarity — NOT a random
    /// sample of a wide net, so the result actually sounds like the seed artist.
    ///
    /// `genres` (Roon genre per track id) layers genre-affinity on top of CLAP
    /// texture similarity: neighbours that SHARE a genre with the seed artist come
    /// first (nearest within that group), then off-genre neighbours fill any
    /// remaining slots. CLAP alone matches mood/texture and drifts across genres
    /// (a mellow dance ballad near indie rock); the genre layer keeps it on-genre
    /// without risking an under-filled playlist.
    nonisolated static func buildPlaylistCandidates(
        seedIds: [String], lib: [DatabaseManager.SonicTrack], index: VectorIndex?,
        genres: [String: Set<String>] = [:]
    ) -> [TrackRecord] {
        let seedSet = Set(seedIds)
        let own = lib.filter { seedSet.contains($0.id) }
        guard !own.isEmpty else { return [] }
        let neighbours = SonicEngine.nearest(toSeeds: own, in: lib, limit: 200, index: index).map(\.track)

        var seedGenres = Set<String>()
        for id in seedIds { if let g = genres[id] { seedGenres.formUnion(g) } }
        // Drop "umbrella" genres that sit on a large share of the library (e.g.
        // Roon's "Pop/Rock"): they match almost everything, so anchoring on them
        // is no better than no filter. Only discriminating genres remain.
        if !genres.isEmpty {
            let total = max(1, genres.count)
            var freq: [String: Int] = [:]
            for gs in genres.values { for g in gs { freq[g, default: 0] += 1 } }
            seedGenres = seedGenres.filter { Double(freq[$0] ?? 0) / Double(total) <= 0.35 }
        }

        let ordered: [DatabaseManager.SonicTrack]
        if seedGenres.isEmpty {
            ordered = own + neighbours          // no genre data → pure nearest
        } else {
            func sharesGenre(_ t: DatabaseManager.SonicTrack) -> Bool {
                genres[t.id].map { !$0.isDisjoint(with: seedGenres) } ?? false
            }
            // Both halves keep their similarity order.
            ordered = own + neighbours.filter(sharesGenre) + neighbours.filter { !sharesGenre($0) }
        }

        var seen = Set<String>()
        var deduped: [DatabaseManager.SonicTrack] = []
        for t in ordered where seen.insert(t.id).inserted { deduped.append(t) }
        return deduped.map { TrackRecord(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) }
    }

    // MARK: AI title + description

    // `v2`: the prompt now steers titles toward the sonic profile (genre / mood
    // / energy) instead of abstract wordplay. Bumping the key regenerates the
    // earlier vague titles on next build.
    private static func titleKey(_ id: String) -> String  { "artistradio.title.v2.\(id)" }
    private static func descKey(_ id: String) -> String   { "artistradio.desc.v2.\(id)" }
    static func qobuzIDKey(_ id: String) -> String        { "artistradio.qobuzid.\(id)" }

    /// Cached AI title/description for a radio (generated once so the Qobuz name
    /// stays stable), generating + persisting them on first use. `profile` is the
    /// sonic-profile summary used to steer the title.
    func aiTitleAndDescription(for radio: SonicRadio, sample: [TrackRecord], profile: String) async -> (title: String, description: String) {
        let d = UserDefaults.standard
        if let t = d.string(forKey: Self.titleKey(radio.id)), !t.isEmpty,
           let desc = d.string(forKey: Self.descKey(radio.id)), !desc.isEmpty {
            return (t, desc)
        }
        let meta = await Self.generateAIMeta(artist: radio.artist, sample: sample, profile: profile)
        d.set(meta.title, forKey: Self.titleKey(radio.id))
        d.set(meta.description, forKey: Self.descKey(radio.id))
        return meta
    }

    /// A compact Dutch summary of the selection's sonic character — dominant
    /// tags/genres, top moods, energy band and tempo — fed to the title prompt so
    /// titles describe *what kind of music* it is, not just a clever phrase.
    nonisolated static func sonicProfileSummary(_ tracks: [DatabaseManager.SonicTrack]) -> String {
        guard !tracks.isEmpty else { return "" }
        var parts: [String] = []

        // Dominant tags / genres.
        var tagCounts: [String: Int] = [:]
        for t in tracks { for tag in t.tags { tagCounts[tag.lowercased(), default: 0] += 1 } }
        let topTags = tagCounts.sorted { $0.value > $1.value }.prefix(4).map(\.key)
        if !topTags.isEmpty { parts.append("genres/tags: \(topTags.joined(separator: ", "))") }

        // Top moods (averaged cosine across the selection).
        var moodSum: [String: Float] = [:]
        for t in tracks { for (m, v) in t.moods { moodSum[m, default: 0] += v } }
        let topMoods = moodSum.sorted { $0.value > $1.value }.prefix(2).map(\.key)
        if !topMoods.isEmpty { parts.append("sfeer: \(topMoods.joined(separator: ", "))") }

        // Energy band.
        let energies = tracks.compactMap(\.energy)
        if !energies.isEmpty {
            let avg = energies.reduce(0, +) / Double(energies.count)
            let band = avg < 0.4 ? "rustig" : (avg < 0.7 ? "gemiddeld" : "energiek")
            parts.append("energie: \(band)")
        }

        // Tempo.
        let bpms = tracks.compactMap(\.bpm).filter { $0 > 0 }
        if !bpms.isEmpty {
            let avg = Int((bpms.reduce(0, +) / Double(bpms.count)).rounded())
            parts.append("±\(avg) BPM")
        }
        return parts.joined(separator: "; ")
    }

    /// Ask the configured LLM for a Dutch title that names the sonic profile +
    /// a short description, as strict JSON. Falls back to a tidy default when the
    /// LLM isn't configured, errors, or returns unparseable output.
    nonisolated static func generateAIMeta(artist: String, sample: [TrackRecord], profile: String) async -> (title: String, description: String) {
        let fallbackTitle = "Radio rond \(artist)"
        let fallbackDesc  = "Een eindeloze radio rond \(artist) en muzikaal verwante artiesten uit je bibliotheek."

        let examples = sample.prefix(8)
            .map { "• \($0.title) — \($0.artist ?? "onbekend")" }
            .joined(separator: "\n")
        let others = Array(Set(sample.compactMap { $0.artist }
            .filter { $0.lowercased() != artist.lowercased() }))
            .prefix(6).joined(separator: ", ")

        let system = """
        Je bent een muziekredacteur die pakkende, INFORMATIEVE Nederlandse playlist-titels schrijft. \
        Antwoord UITSLUITEND met strikt geldige JSON, exact in de vorm \
        {"title": "...", "description": "..."}. Geen uitleg, geen markdown, geen codeblok.
        """
        let user = """
        Maak een titel en korte beschrijving voor een radio-playlist rond de artiest "\(artist)".

        Sonisch profiel van de selectie: \(profile.isEmpty ? "onbekend" : profile)
        Voorbeeldtracks:
        \(examples)
        Verwante artiesten: \(others.isEmpty ? "diverse" : others)

        Eisen voor "title":
        - Maak METEEN duidelijk wat voor muziek/sfeer het is: noem het genre/stijl en/of de sfeer of energie (bv. "Melodieuze indie-rock", "Dromerige akoestische avond", "Energieke house").
        - Mag de artiest noemen, maar dat hoeft niet. Vermijd vage woordgrappen die het genre niet verraden.
        - Gebruik UITSLUITEND bestaande, correct gespelde Nederlandse woorden (Engelse genrenamen mogen). Verzin GEEN woorden.
        - Kort en krachtig: MAX 45 tekens, het liefst korter. Niet het saaie "Radio: \(artist)".

        Eisen voor "description":
        - 1 à 2 korte zinnen, vlot en correct Nederlands. Beschrijf de stijl/sfeer en noem een paar kenmerkende artiesten of het genre. Verzin geen woorden.
        """

        let config = LLMConfigStore.load()
        guard let raw = try? await LLMClient.shared.complete(system: system, user: user, config: config) else {
            return (fallbackTitle, fallbackDesc)
        }
        return parseTitleJSON(raw, fallbackTitle: fallbackTitle, fallbackDesc: fallbackDesc)
    }

    /// Defensively extract `{title, description}` from a (possibly fenced /
    /// chatty) LLM reply, falling back per-field on anything missing.
    nonisolated static func parseTitleJSON(_ raw: String, fallbackTitle: String, fallbackDesc: String) -> (title: String, description: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end,
              let data = String(s[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (fallbackTitle, fallbackDesc) }

        var title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var desc  = (obj["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty { title = fallbackTitle }
        title = clampTitle(title, max: 45)
        if desc.isEmpty { desc = fallbackDesc }
        return (title, desc)
    }

    /// Hard length cap on a title, cut at a word boundary so an over-long LLM
    /// reply never dangles a half word or a trailing connector ("&", ":", "-").
    nonisolated static func clampTitle(_ title: String, max: Int) -> String {
        guard title.count > max else { return title }
        let head = String(title.prefix(max))
        // Prefer the last space so we don't slice mid-word.
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " &:-–—,·"))
    }

    // MARK: Qobuz sync

    /// Build the AI artist radios and mirror each to its stable Qobuz playlist
    /// (find-or-create by name, replace contents, push AI description). Returns
    /// the number of playlists successfully synced. Surfaces a toast (and returns
    /// 0) when Qobuz isn't configured or there's nothing to build.
    @discardableResult
    public func syncArtistRadiosToQobuz() async -> Int {
        guard let email = KeychainStore.load(key: "qobuz_email"), !email.isEmpty,
              let pw = KeychainStore.load(key: "qobuz_password"), !pw.isEmpty else {
            reportError("Qobuz is niet ingesteld — vul je inloggegevens in bij Instellingen.")
            return 0
        }
        let playlists = await buildArtistRadioPlaylists()
        guard !playlists.isEmpty else {
            reportError("Geen artiesten-radio's om te synchroniseren — analyseer eerst meer muziek.")
            return 0
        }

        var synced = 0
        for pl in playlists {
            let name = pl.qobuzName
            let pairs = pl.tracks.map { (title: $0.title, artist: $0.artist) }
            if let result = await QobuzClient.shared.syncPlaylist(
                name: name, description: pl.description, tracks: pairs, email: email, password: pw) {
                UserDefaults.standard.set(result.playlistID, forKey: Self.qobuzIDKey(pl.id))
                synced += 1
                Log.info("AI artiesten-radio gesynct naar Qobuz: '\(name)' (\(result.matched)/\(result.total) tracks)",
                         category: .network)
            } else {
                Log.warning("AI artiesten-radio sync mislukt voor '\(name)' (Qobuz-login of -aanmaak faalde)",
                            category: .network)
            }
        }
        return synced
    }

    // MARK: Auto-refresh (server build)

    /// Start the periodic Qobuz sync. No-op unless this is the always-on server
    /// build (`.direct`); the client apps sync on demand via the UI button.
    public func startArtistRadioRefresh() {
        guard controlMode == .direct, artistRadioRefreshTask == nil else { return }
        artistRadioRefreshTask = Task { [weak self] in
            // Brief grace so the server can connect to Roon + load its library on
            // launch before the first attempt.
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                var didSync = false
                if self.qobuzConfigured {
                    let n = await self.syncArtistRadiosToQobuz()
                    didSync = n > 0
                    Log.info("Artiesten-radio auto-sync: \(n) playlist(s) naar Qobuz gezet", category: .network)
                } else {
                    Log.warning("Artiesten-radio auto-sync overgeslagen — Qobuz is niet ingesteld op de server (Instellingen → Server).", category: .network)
                }
                // Re-sync on the full cadence once it's working; retry sooner while
                // still warming up (library/features not ready yet, or no Qobuz).
                let wait = didSync ? Self.artistRadioRefreshInterval : 15 * 60 * 1_000_000_000
                try? await Task.sleep(nanoseconds: wait)
            }
        }
        Log.info("AI artiesten-radio auto-sync gestart (eerste poging na 20s, daarna elke 3 uur)", category: .roon)
    }

    public func stopArtistRadioRefresh() {
        artistRadioRefreshTask?.cancel()
        artistRadioRefreshTask = nil
    }
}
