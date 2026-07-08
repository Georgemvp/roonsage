import AudioAnalysis
import Foundation
import Observation
import RoonProtocol

@MainActor
extension RoonClient {
    // MARK: - Audio features (synced from the native analyzer)

    public var analyzerURL: String {
        get { UserDefaults.standard.string(forKey: "analyzer_url") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "analyzer_url") }
    }

    /// A/B flag (Track E5): when off, Similar / Fingerprint / Path / Alchemy /
    /// Map fall back to the rule-based BPM/Camelot/tag engine even if CLAP
    /// embeddings exist — keeps the scalar baseline comparable before retiring
    /// it. Default on.
    public var useSonicEmbeddings: Bool {
        get { (UserDefaults.standard.object(forKey: "sonic_use_embeddings") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sonic_use_embeddings") }
    }

    /// The vector index when embeddings are enabled, else nil (→ rule-based).
    func activeIndex(_ db: DatabaseManager) async -> VectorIndex? {
        useSonicEmbeddings ? await sonicCache.vectorIndex(from: db) : nil
    }

    /// Default radio adventurousness (familiar ↔ explorative), 0…1.
    public nonisolated static let defaultAdventurousness = 0.35

    /// How adventurous the smart radios are: 0 = vertrouwd (dicht + bekend),
    /// 1 = avontuurlijk (ver + nieuw). Drives the novelty bias and MMR diversity
    /// in `RadioEngine`. The one knob that turns a station from a cosy deep-cut
    /// hour into a voyage. Default 0.35.
    public var radioAdventurousness: Double {
        get { (UserDefaults.standard.object(forKey: "radio_adventurousness") as? Double) ?? Self.defaultAdventurousness }
        set { UserDefaults.standard.set(min(1, max(0, newValue)), forKey: "radio_adventurousness") }
    }

    /// Hard-ban thumbed-down tracks from radios entirely, instead of the default
    /// soft down-sampling (≈1/4 as often). Default false.
    public var radioHardBanDisliked: Bool {
        get { UserDefaults.standard.bool(forKey: "radio_hard_ban_disliked") }
        set { UserDefaults.standard.set(newValue, forKey: "radio_hard_ban_disliked") }
    }

    /// Let the CLAP attribute axes (valence/danceability/acousticness/
    /// instrumentalness) feed the radios (steering the AI titles/profile). On by
    /// default since the axes are now library-calibrated (percentile bands via
    /// `TitleGrounding.Calibration`) and generated titles are validated against
    /// the measured values — a mis-scaled zero-shot score can no longer put a
    /// false claim in a station name.
    public var radioAttributesEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "radio_attributes_enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "radio_attributes_enabled") }
    }

    /// Attribute scores (valence/danceability/…) for a now-playing track, if synced.
    public func attributesFor(title: String, artist: String?, album: String?) -> [String: Float] {
        database?.attributesForMatchKey(TrackIdentity.matchKey(artist: artist, album: album, title: title)) ?? [:]
    }

    /// Lowercased artist names the user actually engages with — those they play
    /// most (Roon + Last.fm history) plus those they've thumbed up. The "familiar"
    /// set the smart radios lean toward at low adventurousness (and away from when
    /// you crank the dial). Empty on a fresh client with no history yet.
    func knownArtistKeys(lib: [DatabaseManager.SonicTrack]) async -> Set<String> {
        var known = Set<String>()
        if isRemote {
            let snap = await tasteProfile(topLimit: 200, recentLimit: 1)
            for a in (snap?.topArtists ?? []) { known.insert(a.artist.lowercased()) }
        } else if let db = database {
            for e in ((try? await db.topArtistsListened(limit: 200)) ?? []) {
                known.insert(e.artist.lowercased())
            }
        }
        known.formUnion(feedbackArtistTallies(lib: lib).liked.keys)
        return known
    }

    /// Track-level play stats (content key → plays + last played). The server
    /// build reads its own `listening_history`; thin clients pull the same rows
    /// from the server's `/play-stats` (history lives there). `since` (ISO8601)
    /// restricts to plays at/after that moment — Sonic DNA's evolution window.
    public func playStats(since: String? = nil) async -> [SonicDNA.PlayStat] {
        if isRemote {
            guard let base = remoteBaseURL else { return [] }
            var comp = URLComponents(string: "\(base)/play-stats")
            if let since { comp?.queryItems = [URLQueryItem(name: "since", value: since)] }
            guard let url = comp?.url else { return [] }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            authorizeShareRequest(&req)
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let stats = try? JSONDecoder().decode([SonicDNA.PlayStat].self, from: data)
            else { return [] }
            return stats
        }
        guard let db = database else { return [] }
        let rows = (try? await db.playStatsByMatchKey(since: since)) ?? []
        return rows.map { SonicDNA.PlayStat(matchKey: $0.matchKey, count: $0.count, lastPlayed: $0.lastPlayed) }
    }

    /// The user's recency-weighted taste vector in CLAP space, used to bias every
    /// station toward what they actually love. Computed from `listening_history`
    /// + likes; on thin clients the stats come from the server's `/play-stats`,
    /// so the vector now works there too (an older server without that endpoint
    /// just yields nil and the station leans on its seeds instead).
    func personalTasteVector(lib: [DatabaseManager.SonicTrack], index: VectorIndex?) async -> [Float]? {
        guard let index else { return nil }
        let stats = await playStats().map { (matchKey: $0.matchKey, count: $0.count, lastPlayed: $0.lastPlayed) }
        let liked = likedMatchKeys
        guard !stats.isEmpty || !liked.isEmpty else { return nil }
        return await Task.detached {
            TasteVector.compute(stats: stats, likedKeys: liked, index: index)
        }.value
    }

    public func audioFeaturesStats() async -> (total: Int, matched: Int) {
        guard let db = database else { return (0, 0) }
        return (try? await db.audioFeaturesStats()) ?? (0, 0)
    }

    /// Total play-time of the analysed library, in seconds.
    public func libraryDurationSeconds() async -> Double {
        guard let db = database else { return 0 }
        return (try? await db.libraryDurationSeconds()) ?? 0
    }

    /// The library's MusicBrainz genre hierarchy (parent → subgenres), for the
    /// MCP `get_genre_tree` tool and a hierarchical genre picker.
    public func libraryGenreTree() async -> [DatabaseManager.GenreTreeNode] {
        guard let db = database else { return [] }
        return (try? await db.genreTree()) ?? []
    }

    /// Pull all features from the analyzer's HTTP endpoint, upsert them, and
    /// reconcile them against the library (exact match_key + fuzzy fallback).
    /// Returns the match diagnostic, or nil on failure.
    public func syncAudioFeatures(from baseURL: String) async -> DatabaseManager.AudioFeatureDiagnostic? {
        guard let payload = await fetchFeaturePayload(from: baseURL) else { return nil }
        let db = database
        let diag = await Task.detached { () -> DatabaseManager.AudioFeatureDiagnostic? in
            try? await db?.upsertAudioFeatures(payload.features)
            // Fuzzy fallback rewrites tracks.match_key for confident matches so the
            // DJ/Sonic joins pick them up; apply on a real sync.
            let d = try? await db?.reconcileFeatureMatches(payload.identities, apply: true)
            // Backfill tracks.year from the analyzer's file tags (Roon Browse has no
            // year). After reconcile so fuzzy-rewritten match_keys also resolve.
            try? await db?.applyTrackYears(payload.years)
            // MusicBrainz genres (keyed by match_key, like features) — the richer
            // genre set the analyzer enriched.
            try? await db?.upsertMBGenres(payload.genres)
            return d
        }.value
        // Pull the 512-dim embeddings (binary bundle) after match_keys are
        // reconciled, so they attach to the right rows.
        await pullEmbeddings(from: baseURL)
        // Pull the genre hierarchy so a filter on a parent genre expands to its
        // subgenres. Best-effort: older analyzers without /genres yield nothing.
        await pullGenreTaxonomy(from: baseURL)
        await sonicCache.invalidate()
        return diag
    }

    /// Periodically ingest the analyzer's features into library.db on the
    /// always-on server build (`.direct`). The analyzer serves /features +
    /// /embeddings on :5766, but nothing pulled them into the library
    /// automatically — so tags/year/embeddings only landed via the Settings
    /// button or a client pull. This closes that gap.
    ///
    /// Gated on the analyzer's feature revision (count/embedded signature): we
    /// re-sync only when it changes (new analyses), so the heavy /embeddings
    /// pull doesn't repeat needlessly. Retries on a short cadence until the
    /// feature server is up and the library is populated, then idles long.
    public func startServerFeatureSync() {
        guard controlMode == .direct, serverFeatureSyncTask == nil else { return }
        serverFeatureSyncTask = Task { [weak self] in
            // Let launch (Roon connect + library sync + artist-radio) settle first.
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                let url = self.analyzerURL.trimmingCharacters(in: .whitespaces)
                let rev = self.featuresRevision
                let lastRev = (try? self.database?.syncStateValue(forKey: "features_synced_revision")) ?? nil

                var settled = false
                if url.isEmpty || rev.isEmpty || self.trackCount == 0 {
                    settled = false                       // not ready yet — retry soon
                } else if rev == lastRev {
                    settled = true                        // already synced this revision
                } else if let diag = await self.syncAudioFeatures(from: url) {
                    try? await self.database?.setSyncState(key: "features_synced_revision", value: rev)
                    Log.info("Server feature-sync: \(diag.featureRows) features, \(diag.exactMatched + diag.fuzzyMatched)/\(diag.libraryTracks) gematcht", category: .network)
                    settled = true
                }
                // Long idle once up-to-date; short retry while warming up / on failure.
                let wait: UInt64 = settled ? 6 * 60 * 60 * 1_000_000_000 : 5 * 60 * 1_000_000_000
                try? await Task.sleep(nanoseconds: wait)
            }
        }
    }

    public func stopServerFeatureSync() {
        serverFeatureSyncTask?.cancel()
        serverFeatureSyncTask = nil
    }

    /// Fetch the analyzer's binary `/embeddings` bundle and attach the vectors
    /// to the feature rows by match_key. Best-effort: older analyzers without
    /// the endpoint simply yield no embeddings.
    private func pullEmbeddings(from baseURL: String) async {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "\(trimmed)/embeddings") else { return }
        var req = URLRequest(url: url)
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        let db = database
        _ = await Task.detached { try? await db?.applyEmbeddingsBlob(data) }.value
    }

    /// Fetch the analyzer's `/genres` taxonomy ([{genre, parent?, mbid?}]) and
    /// upsert it so subgenre expansion works in filters. Best-effort: an older
    /// analyzer without the endpoint, or an empty taxonomy, is a no-op.
    private func pullGenreTaxonomy(from baseURL: String) async {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "\(trimmed)/genres") else { return }
        var req = URLRequest(url: url)
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        let db = database
        _ = await Task.detached { () -> Void in
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            let nodes: [(genre: String, parent: String?, mbid: String?)] = arr.compactMap { o in
                guard let g = o["genre"] as? String, !g.isEmpty else { return nil }
                return (g, o["parent"] as? String, o["mbid"] as? String)
            }
            try? await db?.upsertGenreTaxonomy(nodes)
        }.value
    }

    /// Read-only: fetch features and report the match breakdown WITHOUT mutating
    /// the library (no fuzzy rewrites). For the Settings "Diagnose" action.
    public func diagnoseAudioFeatures(from baseURL: String) async -> DatabaseManager.AudioFeatureDiagnostic? {
        guard let payload = await fetchFeaturePayload(from: baseURL) else { return nil }
        let db = database
        return await Task.detached { () -> DatabaseManager.AudioFeatureDiagnostic? in
            try? await db?.reconcileFeatureMatches(payload.identities, apply: false)
        }.value
    }

    private struct FeaturePayload: Sendable {
        var features: [DatabaseManager.AudioFeatureRow]
        var identities: [DatabaseManager.FeatureIdentity]
        // (match_key, year) from the analyzer's file tags — Roon's Browse API
        // doesn't expose the release year, so we backfill tracks.year from here.
        var years: [(matchKey: String, year: Int)]
        // (match_key, MusicBrainz genres) — the richer, hierarchical genre set
        // the analyzer enriched. Stored in track_mb_genres, joined by match_key.
        var genres: [(matchKey: String, genres: [String])]
    }

    /// Fetch + parse the analyzer `/features` JSON off the main actor.
    private func fetchFeaturePayload(from baseURL: String) async -> FeaturePayload? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "\(trimmed)/features") else { return nil }
        var req = URLRequest(url: url)
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return await Task.detached { () -> FeaturePayload? in
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            var features: [DatabaseManager.AudioFeatureRow] = []
            var identities: [DatabaseManager.FeatureIdentity] = []
            var years: [(matchKey: String, year: Int)] = []
            var genres: [(matchKey: String, genres: [String])] = []
            features.reserveCapacity(arr.count); identities.reserveCapacity(arr.count)
            for o in arr {
                guard let mk = o["match_key"] as? String, !mk.isEmpty else { continue }
                features.append(DatabaseManager.AudioFeatureRow(
                    matchKey: mk,
                    bpm: o["bpm"] as? Double, camelot: o["camelot"] as? String,
                    keyRoot: o["key_root"] as? String, keyMode: o["key_mode"] as? String,
                    energy: o["energy"] as? Double, duration: o["duration"] as? Double,
                    tags: o["tags"] as? String, moods: o["moods"] as? String,
                    bpmConfidence: o["bpm_confidence"] as? Double,
                    attributes: o["attributes"] as? String,
                    popularity: o["popularity"] as? Int,
                    loudness: o["loudness"] as? Double,
                    isrc: o["isrc"] as? String,
                    recordingMbid: o["recording_mbid"] as? String
                ))
                identities.append(DatabaseManager.FeatureIdentity(
                    matchKey: mk, artist: o["artist"] as? String, title: o["title"] as? String))
                if let y = o["year"] as? Int, y > 1900 { years.append((mk, y)) }
                if let g = o["mb_genres"] as? [String], !g.isEmpty { genres.append((mk, g)) }
            }
            return FeaturePayload(features: features, identities: identities, years: years, genres: genres)
        }.value
    }

    // MARK: - DJ sets

    public func buildDJSet(
        count: Int, startBPM: Double, endBPM: Double,
        curve: DJSetBuilder.Curve, tags: [String], excludeLive: Bool = true
    ) async -> [DatabaseManager.DJCandidate] {
        guard let db = database else { return [] }
        do {
            return try await Task.detached {
                let cands = try await db.djCandidates(
                    minBPM: min(startBPM, endBPM), maxBPM: max(startBPM, endBPM),
                    tags: tags, excludeLive: excludeLive
                )
                return DJSetBuilder.build(candidates: cands, count: count, startBPM: startBPM, endBPM: endBPM, curve: curve)
            }.value
        } catch {
            Log.warning("DJ-set bouwen mislukt: \(error)", category: .roon)
            reportError("DJ-set bouwen mislukt — probeer het opnieuw.")
            return []
        }
    }

    /// Audio features for a now-playing track (by content match key), if synced.
    public func featuresFor(title: String, artist: String?, album: String?) -> (bpm: Double, camelot: String, tags: [String])? {
        database?.featuresForMatchKey(TrackIdentity.matchKey(artist: artist, album: album, title: title))
    }

    /// Build an endless-style mix seeded from a track: harmonically-compatible
    /// tracks within ±12 BPM of the seed, ordered by the DJ-set builder.
    public func buildRadio(title: String, artist: String?, album: String?, count: Int = 25) async -> [DatabaseManager.DJCandidate] {
        guard let db = database,
              let seed = featuresFor(title: title, artist: artist, album: album), seed.bpm > 0 else { return [] }
        return await Task.detached {
            let cands = (try? await db.djCandidates(minBPM: seed.bpm - 12, maxBPM: seed.bpm + 12, tags: [], excludeLive: true)) ?? []
            guard !cands.isEmpty else { return [] }
            return DJSetBuilder.build(candidates: cands, count: count, startBPM: seed.bpm, endBPM: seed.bpm, curve: .flat)
        }.value
    }

    // MARK: - Live DJ (next-track suggestions)

    public enum HarmonicRelation: Sendable {
        case harmonic   // adjacent on the Camelot wheel — smoothest mix
        case sameKey    // identical key
        case tempo      // tempo-compatible only
    }

    /// How a candidate's Camelot key mixes with the current key (for UI badges).
    public nonisolated static func harmonicRelation(current: String, candidate: String) -> HarmonicRelation {
        guard !current.isEmpty, !candidate.isEmpty else { return .tempo }
        if current == candidate { return .sameKey }
        if Camelot.compatible(current).contains(candidate) { return .harmonic }
        return .tempo
    }

    /// Live-DJ suggestions: tracks that mix well RIGHT NOW after the given key/BPM —
    /// within a tight BPM window, ranked by Camelot-harmonic compatibility, BPM
    /// proximity and energy. Runs off the main actor (blocking pool.read).
    public func harmonicNextTracks(bpm: Double, camelot: String, excludeID: String? = nil,
                                   limit: Int = 25) async -> [DatabaseManager.DJCandidate] {
        guard let db = database, bpm > 0 else { return [] }
        let lo = bpm - 8, hi = bpm + 8
        let compatible = Camelot.compatible(camelot)
        return await Task.detached {
            let cands = (try? await db.djCandidates(minBPM: lo, maxBPM: hi, tags: [], excludeLive: true)) ?? []
            func rank(_ c: DatabaseManager.DJCandidate) -> Double {
                let bpmPen = abs(c.bpm - bpm) / 4.0
                let harm: Double
                if !camelot.isEmpty, c.camelot == camelot { harm = 0.2 }
                else if compatible.contains(c.camelot) { harm = 0.0 }
                else { harm = 1.0 }
                return bpmPen + harm - c.energy * 0.1
            }
            return cands.filter { $0.id != excludeID }
                .sorted { rank($0) < rank($1) }
                .prefix(limit)
                .map { $0 }
        }.value
    }

    public func playDJSet(_ set: [DatabaseManager.DJCandidate], zoneID: String) async {
        let tracks = set.map { TrackRecord(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) }
        await curateTracks(tracks, zoneID: zoneID)
    }

    public func saveDJSet(name: String, set: [DatabaseManager.DJCandidate]) {
        let tracks = set.map { TrackRecord(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) }
        _ = savePlaylist(name: name, tracks: tracks)
    }

    // MARK: - Discovery sections

    public func undiscoveredAlbums(limit: Int = 16) async -> [DatabaseManager.AlbumResult] {
        guard let db = database else { return [] }
        return (try? await db.undiscoveredAlbums(limit: limit)) ?? []
    }

    public func forgottenFavorites(days: Int = 60, limit: Int = 20) async -> [TrackRecord] {
        guard let db = database else { return [] }
        return (try? await db.forgottenFavorites(days: days, limit: limit)) ?? []
    }

    public func topTracks(limit: Int = 25) async -> [TrackRecord] {
        guard let db = database else { return [] }
        return (try? await db.topTracks(limit: limit)) ?? []
    }

    /// Filter by `options`, shuffle, and play a random `count`-track mix.
    public func playShuffledMix(options: DatabaseManager.FilterOptions, count: Int, zoneID: String) async {
        var opts = options
        opts.limit = max(opts.limit, 500)
        var pool = await filterTracks(options: opts)
        pool.shuffle()
        let pick = Array(pool.prefix(count))
        guard !pick.isEmpty else { return }
        await curateTracks(pick, zoneID: zoneID)
    }

    /// Play every track of an album by its album_key (first plays, rest queue).
    public func playAlbum(albumKey: String, zoneID: String) async {
        var opts = DatabaseManager.FilterOptions()
        opts.albumKey = albumKey
        opts.excludeLive = false
        opts.limit = 200
        let tracks = await filterTracks(options: opts)
        guard !tracks.isEmpty else { return }
        await curateTracks(tracks, zoneID: zoneID)
    }

    /// Play an artist's library tracks to a zone (first plays, rest queue).
    public func playArtist(name: String, zoneID: String) async {
        var opts = DatabaseManager.FilterOptions()
        opts.artists = [name]
        opts.limit = 200
        let tracks = await filterTracks(options: opts)
        guard !tracks.isEmpty else { return }
        await curateTracks(tracks, zoneID: zoneID)
    }

    // MARK: - Sonic similarity (Radio / Fingerprint)

    /// Library tracks sonically similar to a seed (tempo, key, energy, tags).
    /// Heavy scan runs off the main actor.
    public func similarTracks(toMatchKey matchKey: String, limit: Int = 30) async -> [SonicEngine.Scored] {
        guard let db = database, !matchKey.isEmpty else { return [] }
        let lib = await radioLibrary()
        let index = await activeIndex(db)
        let disliked = dislikedMatchKeys
        let liked = likedMatchKeys
        let known = await knownArtistKeys(lib: lib)
        let adv = radioAdventurousness
        // Prefer the seed as it appears in the analyzed library (it carries a
        // real track id, so the engine's id-based embedding k-NN can fire).
        // Fall back to a seed synthesized straight from track_audio_features
        // when the now-playing track isn't in the joined library — a
        // streaming/Qobuz track, an is_live row, or one whose library
        // match_key diverges from the analyzer's. Without this, Radio seeded
        // from such a track silently returned [] (spinner, then nothing).
        let inLib = lib.first(where: { $0.matchKey == matchKey })
        guard let seed = inLib ?? db.sonicSeed(matchKey: matchKey) else { return [] }
        let seedInLib = inLib != nil
        return await Task.detached {
            let raw: [SonicEngine.Scored]
            if seedInLib, let index, index.embedding(forId: seed.id) != nil {
                // Smart "more like this": multi-anchor relevance + the adventurousness
                // dial + a flow-ordered result. Ask for a margin to survive the
                // seed-prune + dedup below.
                let opts = RadioEngine.Options(adventurousness: adv, poolLimit: limit + 6, sequence: true)
                raw = RadioEngine.rank(
                    seeds: [seed], library: lib, index: index, options: opts,
                    disliked: disliked, likedKeys: liked, knownArtists: known,
                    salt: "similar\u{1f}\(seed.matchKey)")
                    .map { SonicEngine.Scored(track: $0.track, similarity: min(1, max(0, $0.score)), reason: $0.reason) }
            } else if seedInLib {
                raw = SonicEngine.similar(to: seed, in: lib, limit: limit + 1, index: index)
            } else if let index, let emb = seed.embedding, !emb.isEmpty {
                // Synthesized seed has no id in the index — drive the embedding
                // k-NN off its vector directly.
                raw = index.nearest(to: emb, k: limit + 1)
                    .map { SonicEngine.Scored(track: $0.track, similarity: Double(max(0, $0.score))) }
            } else {
                // No embedding (or A/B off): rule-based scoring on bpm/key/energy/tags.
                raw = SonicEngine.similar(to: seed, in: lib, limit: limit + 1, index: nil)
            }
            // Drop the seed itself, then collapse duplicate copies of the same
            // song (same content key on a different album / Roon id) so the
            // station never queues a track twice.
            var seen = Set<String>()
            let pruned = raw.filter { s in
                guard s.track.matchKey != seed.matchKey else { return false }
                let k = s.track.matchKey
                return k.isEmpty ? true : seen.insert(k).inserted
            }
            // Down-sample (not ban) disliked tracks so they surface much less often.
            return Array(RoonClient.applyFeedbackWeighting(
                pruned, disliked: disliked, salt: "similar\u{1f}\(seed.matchKey)",
                matchKey: { $0.track.matchKey }).prefix(limit))
        }.value
    }

    /// The CLAP k-NN index over the analyzed library (nil when too few
    /// embeddings exist or the A/B flag is off). For UI features that drive the
    /// engine directly.
    public func sonicVectorIndex() async -> VectorIndex? {
        guard let db = database else { return nil }
        return await activeIndex(db)
    }

    /// Free-text → audio search: the analyzer embeds the query text (CLAP shared
    /// space) via /text-embed, then we cosine-rank the local embedding index.
    /// Returns [] when the analyzer/text model or embeddings are unavailable.
    public func sonicTextSearch(_ query: String, limit: Int = 40) async -> [SonicEngine.Scored] {
        guard let db = database, let vec = await requestTextVector(query) else { return [] }
        guard let index = await sonicCache.vectorIndex(from: db) else { return [] }
        return await Task.detached {
            index.nearest(to: vec, k: limit).map {
                SonicEngine.Scored(track: $0.track, similarity: Double(max(0, $0.score)))
            }
        }.value
    }

    /// Ask the LLM for a short ENGLISH "how it should sound" phrase (genre, mood,
    /// instrumentation, energy) for any — including Dutch — request, so the CLAP
    /// text embedding (English-trained) is sharp. nil on failure → caller falls
    /// back to the raw request.
    func sonicPhrase(for request: String) async -> String? {
        let q = request.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let system = """
        Translate a music request into a short ENGLISH phrase (3-8 words) describing how the \
        music should SOUND: genre, mood, instrumentation, energy/tempo. No artist or song names. \
        Respond with ONLY the phrase — no quotes, no prose.
        """
        guard let resp = try? await LLMClient.shared.complete(
            system: system, user: "Request: \(q)", config: effectiveLLMConfig()) else { return nil }
        // `complete` already strips any reasoning block — just tidy the phrase.
        let phrase = resp
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
        return phrase.isEmpty ? nil : String(phrase.prefix(120))
    }

    /// Embed a free-text query into CLAP space via the analyzer's /text-embed.
    /// nil when the query is empty or the analyzer/text model is unavailable.
    func requestTextVector(_ query: String) async -> [Float]? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let base = analyzerURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, var comp = URLComponents(string: "\(base)/text-embed") else { return nil }
        comp.queryItems = [URLQueryItem(name: "q", value: q)]
        guard let url = comp.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["embedding"] as? [Double], !arr.isEmpty else { return nil }
        return arr.map { Float($0) }
    }

    /// Hybrid AI retrieval (Track E6): reorder LLM-filtered candidates by how
    /// sonically close each is to the free-text request (CLAP text embedding),
    /// with a light per-artist cap for variety. Returns nil when reranking isn't
    /// possible (A/B flag off, analyzer text model unavailable, or no
    /// embeddings) so callers fall back to their existing behaviour.
    public func sonicRerank(_ request: String, _ tracks: [TrackRecord],
                            limit: Int, maxPerArtist: Int = 3) async -> [TrackRecord]? {
        guard useSonicEmbeddings, let db = database, !tracks.isEmpty else { return nil }
        // CLAP is English-trained; translate the (possibly Dutch) request into a
        // short English "how it should sound" phrase before embedding.
        let phrase = await sonicPhrase(for: request) ?? request
        guard let vec = await requestTextVector(phrase),
              let index = await sonicCache.vectorIndex(from: db) else { return nil }
        return await Task.detached {
            // match candidates to their (normalized) embedding by content key
            var embByKey = [String: [Float]](minimumCapacity: index.tracks.count)
            for t in index.tracks where !t.matchKey.isEmpty {
                if let e = index.embedding(forId: t.id) { embByKey[t.matchKey] = e }
            }
            guard !embByKey.isEmpty else { return nil }
            let ranked = Self.rankCandidates(tracks, queryVec: vec, embByKey: embByKey,
                                             limit: limit, maxPerArtist: maxPerArtist)
            guard !ranked.isEmpty else { return nil }
            // Coverage guard: rankCandidates drops candidates without an embedding,
            // so on a partially-analysed library the pool would silently shrink to
            // "whatever happens to be analysed". Float the embedded, sonically-
            // relevant tracks to the top but keep the rest (original order) after
            // them, so the curation LLM + top-up still see the full pool.
            let rankedIDs = Set(ranked.map(\.id))
            let leftovers = tracks.filter { !rankedIDs.contains($0.id) }
            return Array((ranked + leftovers).prefix(limit))
        }.value
    }

    /// Pure reranking core: cosine(query, candidate-embedding) descending, with a
    /// per-artist cap for variety. Candidates without an embedding are dropped.
    /// Embeddings are assumed L2-normalized (as stored); the query is normalized
    /// here. Static + side-effect-free so it's directly unit-testable.
    nonisolated static func rankCandidates(_ tracks: [TrackRecord], queryVec: [Float],
                                           embByKey: [String: [Float]], limit: Int, maxPerArtist: Int) -> [TrackRecord] {
        let qv = VectorIndex.normalized(queryVec)
        let scored = tracks.compactMap { t -> (TrackRecord, Float)? in
            guard let mk = t.matchKey, let e = embByKey[mk] else { return nil }
            var dot: Float = 0
            let n = min(qv.count, e.count)
            for i in 0..<n { dot += qv[i] * e[i] }
            return (t, dot)
        }.sorted { $0.1 > $1.1 }
        var perArtist = [String: Int]()
        var out: [TrackRecord] = []
        for (t, _) in scored {
            let a = (t.artist ?? "").lowercased()
            if perArtist[a, default: 0] >= maxPerArtist { continue }
            perArtist[a, default: 0] += 1
            out.append(t)
            if out.count >= limit { break }
        }
        return out
    }

    public func similarTracks(title: String, artist: String?, album: String?, limit: Int = 30) async -> [SonicEngine.Scored] {
        await similarTracks(toMatchKey: TrackIdentity.matchKey(artist: artist, album: album, title: title), limit: limit)
    }

    /// Seed a station from a track and play it. Delegates to the endless
    /// song radio (`startTrackRadio`) — RadioEngine relevance + MMR + taste
    /// steering + live re-steer + endless top-up — instead of the old one-shot
    /// nearest-30 queue dump. An unanalyzed track surfaces the usual toast.
    /// `count` is retained for source compatibility; an endless station ignores it.
    public func playSonicRadio(title: String, artist: String?, album: String?, count: Int = 30, zoneID: String) async {
        await startTrackRadio(title: title, artist: artist, album: album, zoneID: zoneID)
    }

    /// One taste core ("smaakkern"): a coherent pocket of the user's listening,
    /// with its own recommendations.
    public struct TasteCore: Sendable, Identifiable {
        public var id: String
        public var label: String
        public var share: Double          // 0…1 of the listening weight
        public var trackCount: Int
        public var topArtists: [String]
        public var recommendations: [SonicEngine.Scored]
    }

    public struct Fingerprint: Sendable {
        public var profile: SonicDNA.Profile
        /// Profile over the last 90 days (nil when there's too little recent play
        /// history to be meaningful).
        public var recentProfile: SonicDNA.Profile?
        /// Axes where the recent window departs from all-time, biggest first.
        public var evolution: [SonicDNA.AxisDelta]
        public var recommendations: [SonicEngine.Scored]
        public var cores: [TasteCore]
        public var seedCount: Int
        /// false = no play history yet; the profile is a library-wide sample.
        public var usedHistory: Bool
    }

    /// Days of the "recent" window the DNA evolution compares against all-time.
    public nonisolated static let dnaRecentWindowDays = 90

    /// Your "musical DNA": a recency/play-weighted profile of the tracks you
    /// actually listen to (plus likes, minus dislikes), taste cores, an
    /// evolution view, and personalized recommendations. Works on thin clients
    /// too — play stats come from the server's `/play-stats`. Computed off-main.
    public func sonicFingerprint(seedLimit: Int = 80, recommendCount: Int = 40) async -> Fingerprint? {
        guard let db = database else { return nil }
        let lib = await radioLibrary()
        guard !lib.isEmpty else { return nil }
        let index = await activeIndex(db)
        let disliked = dislikedMatchKeys
        let liked = likedMatchKeys
        let known = await knownArtistKeys(lib: lib)
        let adv = radioAdventurousness
        let genres = (try? await db.genresByTrackID()) ?? [:]
        let statsAll = await playStats()
        let cutoff = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-Double(Self.dnaRecentWindowDays) * 86_400))
        let statsRecent = statsAll.isEmpty ? [] : await playStats(since: cutoff)

        return await Task.detached { () -> Fingerprint? in
            let byKey = Dictionary(lib.map { ($0.matchKey, $0) }, uniquingKeysWith: { a, _ in a })

            // Weighted seeds: most-played (recency-decayed) + liked − disliked.
            var seeds = SonicDNA.selectSeeds(
                playStats: statsAll, byMatchKey: byKey, liked: liked,
                disliked: disliked, limit: seedLimit)
            let usedHistory = !seeds.isEmpty
            // No history yet → an evenly-strided library sample (deterministic,
            // not "whatever the cache's first 40 rows happen to be").
            if seeds.isEmpty { seeds = SonicDNA.librarySampleSeeds(lib) }
            guard !seeds.isEmpty else { return nil }

            let profile = SonicDNA.profile(seeds: seeds, index: index, genresById: genres, library: lib)

            // Evolution: the recent window vs all-time, when there's enough signal.
            var recentProfile: SonicDNA.Profile?
            var evolution: [SonicDNA.AxisDelta] = []
            if usedHistory {
                let recentSeeds = SonicDNA.selectSeeds(
                    playStats: statsRecent, byMatchKey: byKey, liked: [],
                    disliked: disliked, limit: seedLimit)
                if recentSeeds.count >= 10 {
                    let rp = SonicDNA.profile(seeds: recentSeeds, index: index, genresById: genres, library: lib)
                    recentProfile = rp
                    evolution = SonicDNA.evolution(recent: rp, allTime: profile)
                }
            }

            // Personal taste vector — same steering the smart radios use.
            let taste: [Float]? = index.flatMap { idx in
                TasteVector.compute(
                    stats: statsAll.map { (matchKey: $0.matchKey, count: $0.count, lastPlayed: $0.lastPlayed) },
                    likedKeys: liked, index: idx)
            }

            // Seed genres for explainability ("past bij je <genre>-smaak").
            let umbrella = SonicDNA.umbrellaGenres(genres)
            var seedGenres = Set<String>()
            for s in seeds {
                for g in genres[s.track.id] ?? [] where !umbrella.contains(g.lowercased()) {
                    seedGenres.insert(g)
                }
            }

            let seedTracks = seeds.map(\.track)   // heaviest first (anchor cap keeps the top)
            let seedKeys = Set(seedTracks.map(\.matchKey).filter { !$0.isEmpty })
            let recRaw: [SonicEngine.Scored]
            if let index, seedTracks.contains(where: { index.embedding(forId: $0.id) != nil }) {
                // Ask for a margin: the dedup + artist cap below prunes the pool.
                let opts = RadioEngine.Options(adventurousness: adv, poolLimit: recommendCount * 3, sequence: false)
                recRaw = RadioEngine.rank(
                    seeds: seedTracks, library: lib, index: index, options: opts,
                    disliked: disliked, likedKeys: liked, knownArtists: known,
                    tasteVector: taste, seedGenres: seedGenres, genresById: genres,
                    seedWeights: seeds.map(\.weight), salt: "fingerprint")
                    // RadioEngine.score carries novelty/discovery bonuses (can exceed
                    // 1) — clamp to a 0…1 similarity for the UI's match %.
                    .map { SonicEngine.Scored(track: $0.track, similarity: min(1, max(0, $0.score)), reason: $0.reason) }
            } else {
                recRaw = SonicEngine.nearest(
                    toSeeds: seedTracks, in: lib, limit: recommendCount * 3, index: index,
                    seedWeights: seeds.map { Float($0.weight) })
            }
            // Down-sample (not ban) disliked, drop the seeds themselves, collapse
            // duplicate copies of one song, and cap per artist for variety.
            let weighted = RoonClient.applyFeedbackWeighting(
                recRaw, disliked: disliked, salt: "fingerprint", matchKey: { $0.track.matchKey })
            let recs = RoonClient.dedupAndCap(
                weighted, excludingKeys: seedKeys, maxPerArtist: 2, limit: recommendCount)

            // Taste cores: weighted k-means over the seeds' embeddings, each core
            // with its own nearest-library recommendations.
            var cores: [TasteCore] = []
            if let index {
                let seedIds = Set(seedTracks.map(\.id))
                for core in SonicDNA.cores(seeds: seeds, index: index, genresById: genres) {
                    let hits = index.nearest(to: core.centroid, k: 40, excludingIds: seedIds)
                        .map { SonicEngine.Scored(track: $0.track, similarity: Double(max(0, $0.score))) }
                    let hitsWeighted = RoonClient.applyFeedbackWeighting(
                        hits, disliked: disliked, salt: "dna-core-\(core.id)", matchKey: { $0.track.matchKey })
                    let coreRecs = RoonClient.dedupAndCap(
                        hitsWeighted, excludingKeys: seedKeys, maxPerArtist: 2, limit: 5)
                    cores.append(TasteCore(
                        id: core.id, label: core.label, share: core.share,
                        trackCount: core.trackIds.count, topArtists: core.topArtists,
                        recommendations: coreRecs))
                }
            }

            return Fingerprint(
                profile: profile, recentProfile: recentProfile, evolution: evolution,
                recommendations: recs, cores: cores, seedCount: seeds.count,
                usedHistory: usedHistory)
        }.value
    }

    /// Content-dedup + per-artist cap over a scored list, preserving order.
    nonisolated static func dedupAndCap(
        _ scored: [SonicEngine.Scored], excludingKeys: Set<String>,
        maxPerArtist: Int, limit: Int
    ) -> [SonicEngine.Scored] {
        var seen = Set<String>()
        var perArtist: [String: Int] = [:]
        var out: [SonicEngine.Scored] = []
        for s in scored {
            let mk = s.track.matchKey
            if !mk.isEmpty {
                if excludingKeys.contains(mk) { continue }
                if !seen.insert(mk).inserted { continue }
            }
            let a = (s.track.artist ?? "").lowercased()
            if perArtist[a, default: 0] >= maxPerArtist { continue }
            perArtist[a, default: 0] += 1
            out.append(s)
            if out.count >= limit { break }
        }
        return out
    }

    /// All analyzed tracks (for the Music Map). Cached; loads off-main.
    public func sonicLibrary() async -> [DatabaseManager.SonicTrack] {
        guard let db = database else { return [] }
        return await sonicCache.tracks(from: db)
    }

    /// Compute the PCA-2D Music Map projection over the CLAP embeddings, persist
    /// map_x/map_y, and invalidate the cache so the next load carries coords.
    /// Returns the number of tracks projected (0 when too few embeddings exist).
    @discardableResult
    public func computeMusicMap() async -> Int {
        guard let db = database, useSonicEmbeddings else { return 0 }
        let lib = await sonicCache.tracks(from: db)
        let coords: [(matchKey: String, x: Double, y: Double)] = await Task.detached {
            let withEmb = lib.filter { ($0.embedding?.count ?? 0) > 0 }
            guard withEmb.count >= 3, let dim = withEmb.first?.embedding?.count else { return [] }
            var flat = [Float](); flat.reserveCapacity(withEmb.count * dim)
            for t in withEmb { flat.append(contentsOf: t.embedding!) }
            let pts = PCAProjector.project(flat: flat, n: withEmb.count, dim: dim)
            guard pts.count == withEmb.count else { return [] }
            return zip(withEmb, pts).map { (matchKey: $0.matchKey, x: Double($1.x), y: Double($1.y)) }
        }.value
        guard !coords.isEmpty else { return 0 }
        let database = db
        do {
            try await database.updateMapCoords(coords)
        } catch {
            Log.warning("Music Map opslaan mislukt: \(error)", category: .roon)
            reportError("Music Map berekenen mislukt — probeer het opnieuw.")
            return 0
        }
        await sonicCache.invalidate()
        return coords.count
    }

    /// Case-insensitive search over the cached sonic library (title + artist).
    /// Returns up to 20 matches. Used by Song Paths and Song Alchemy pickers.
    public func sonicSearch(_ query: String) async -> [DatabaseManager.SonicTrack] {
        guard let db = database else { return [] }
        return await sonicCache.search(query, from: db)
    }

    /// Drop the cached sonic library so the next read hits SQLite. For the
    /// explicit "Reload" actions in Music Map / Sonic DNA.
    public func invalidateSonicCache() async {
        await sonicCache.invalidate()
    }

}
