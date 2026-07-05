import Accelerate
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
    /// it into a single-artist mix; the rest are nearest sonic neighbours. Kept to
    /// ~20-25% of a 20–30 track playlist so the station is a *radio* (the seed plus
    /// discoveries) rather than a seed-artist greatest-hits.
    nonisolated static let artistRadioSeedCap = 6
    /// How many of the 6 seeds are fixed top-played artists (familiar anchor).
    /// The remainder are chosen by max-spread over artist centroids.
    nonisolated static let artistRadioTopCount    = 2
    /// k-NN candidate pool per playlist — larger → more daily variety.
    nonisolated static let artistRadioPoolLimit   = 500
    /// Re-sync cadence on the always-on server build.
    nonisolated static let artistRadioRefreshInterval: UInt64 = 3 * 60 * 60 * 1_000_000_000

    // MARK: Model

    /// One AI artist radio prepared for (or already mirrored to) Qobuz.
    public struct SonicRadioPlaylist: Codable, Sendable, Identifiable {
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

    /// Shared namespace prefix for our Qobuz playlists — also the marker orphan
    /// reconciliation uses to recognise (and prune) stale radio playlists.
    nonisolated static let qobuzNamePrefix = "RoonSage · "
    nonisolated static func qobuzPlaylistName(for title: String) -> String { "\(qobuzNamePrefix)\(title)" }

    // MARK: Stable seed set
    //
    // The 6 seed artists are chosen ONCE and persisted, so every refresh updates
    // the SAME 6 Qobuz playlists. Earlier the seed set was recomputed each build
    // (max-spread over a pool that shifts as the library is analyzed, plus a daily
    // tie-break shuffle), so a refresh could pick different artists → new radio
    // ids → new playlist names → a fresh Qobuz playlist each time, orphaning the
    // old one. That piled up duplicates. Persisting the seeds anchors identity;
    // a seed is only replaced when it stops qualifying (too few analyzed tracks).
    private static let seedKeysKey = "artistradio.seeds.v1"
    static func loadSeedKeys() -> [String] { UserDefaults.standard.stringArray(forKey: seedKeysKey) ?? [] }
    static func saveSeedKeys(_ keys: [String]) { UserDefaults.standard.set(keys, forKey: seedKeysKey) }

    // MARK: Build

    /// Build the ~6 AI artist radios and mirror them to Qobuz.
    ///
    /// Seed strategy: `artistRadioTopCount` (= 2) fixed seeds from the most-played
    /// artists (familiar anchors), then `artistRadioCount - 2` seeds chosen by
    /// max-spread over artist centroids in embedding space — so the 6 playlists
    /// cover maximally different sonic regions instead of all clustering around the
    /// same favourite artists.
    ///
    /// Pool per playlist: `artistRadioPoolLimit` (= 500) k-NN neighbours, daily-
    /// shuffled so the 30 selected tracks rotate every day within that wide pool.
    /// Back-compat wrapper: the artist category (the original behaviour).
    public func buildArtistRadioPlaylists() async -> [SonicRadioPlaylist] {
        await buildRadioPlaylists(category: .artist)
    }

    /// Build the ~6 AI radios for `category` and prepare them for Qobuz. Artist
    /// radios use the stable-seed + max-spread selection; the other categories take
    /// their seeds from `radioBuckets(_:)`. The per-radio playlist build (candidate
    /// pool → cap → AI title) is shared across all categories.
    ///
    /// `restrictKeys` (non-artist only) limits + orders the buckets to those bucket
    /// keys — used by the daypart-aware auto-sync to mirror only a small, time-of-
    /// day-appropriate slice to Qobuz (e.g. a calm set of activities in the morning).
    /// The in-app daily radios and the manual sync pass nil → all buckets.
    public func buildRadioPlaylists(category: RadioCategory, restrictKeys: [String]? = nil) async -> [SonicRadioPlaylist] {
        // Client apps (iOS / macOS thin client) fetch the server's already-synced
        // set so they always show the same playlists as Qobuz.
        if isRemote, let base = remoteBaseURL {
            return await fetchRadiosFromServer(base: base, categoryParam: category.rawValue)
        }
        guard let db = database else {
            Log.warning("Radio's (\(category.rawValue)): geen database beschikbaar — overgeslagen", category: .roon)
            return []
        }
        let lib = await radioLibrary()
        guard !lib.isEmpty else {
            Log.warning("Radio's (\(category.rawValue)): 0 geanalyseerde tracks. Sync eerst de features.", category: .roon)
            return []
        }
        let disliked = radioDislikedMatchKeys
        let liked = likedMatchKeys
        let known = await knownArtistKeys(lib: lib)
        let adv = radioAdventurousness
        let hardBan = radioHardBanDisliked
        let index = await activeIndex(db)
        let taste = await personalTasteVector(lib: lib, index: index)
        let genres = (try? await db.genresByTrackID()) ?? [:]
        // Decade gates key on file-tag years; only fetched when needed.
        let years = category == .decade ? ((try? await db.yearByMatchKey()) ?? [:]) : [:]
        let byId = Dictionary(lib.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let stamp = Self.dayStamp()
        // Library-wide attribute distribution: calibrates the profile descriptors
        // (and thus the AI titles) to THIS library instead of absolute scores.
        let calibration = await Task.detached { TitleGrounding.Calibration.compute(library: lib) }.value

        // Seed radios: artist keeps its stable-seed logic; the others come from the
        // category buckets (whose ids we persist for orphan-safe reconciliation).
        let radios: [SonicRadio]
        if category == .artist {
            radios = await artistSeedRadios(db: db, lib: lib, index: index, disliked: disliked, stamp: stamp)
        } else {
            var buckets = await radioBuckets(category)
            // Daypart filter: keep only the requested bucket keys, in that order.
            // Fall back to the default set if none of them currently qualify.
            if let restrictKeys, !restrictKeys.isEmpty {
                let picked = restrictKeys.compactMap { k in
                    buckets.first { $0.id == "\(category.idPrefix)\(k)" }
                }
                if !picked.isEmpty { buckets = picked }
            }
            let chosen = Array(buckets.prefix(Self.artistRadioCount))
            Self.saveRadioIDs(chosen.map(\.id), category: category)
            radios = chosen.map {
                SonicRadio(id: $0.id, artist: $0.label, imageKey: $0.imageKey,
                           trackCount: $0.trackCount, seedIds: $0.seedIds)
            }
        }
        guard !radios.isEmpty else {
            Log.warning("Radio's (\(category.rawValue)): geen seeds gevonden.", category: .roon)
            return []
        }

        // If any radio may need a generated title — missing, a cached fallback, or
        // titled before the profile-signature mechanism (no stored signature) —
        // warm the (Ollama) model once up front so the first title call below
        // doesn't eat a cold-start timeout and freeze on the fallback. No-op for
        // cloud providers / when all cached and signed.
        let needsTitle = radios.contains { r in
            let t = UserDefaults.standard.string(forKey: Self.titleKey(r.id))
            return (t?.isEmpty ?? true)
                || t == Self.fallbackMeta(category: category, label: r.artist).title
                || UserDefaults.standard.string(forKey: Self.titleSigKey(r.id)) == nil
        }
        if needsTitle { await LLMClient.shared.warmUp(config: LLMConfigStore.load()) }

        var out: [SonicRadioPlaylist] = []
        for radio in radios {
            let seedIds = radio.seedIds
            let key = radio.id
            // Feature fusion: bucket radios gate their candidates on the measured
            // constraint that defines the bucket (nil for artist/sonic). Activity
            // gates read the library energy calibration (percentile-based).
            let gate = Self.bucketGate(radioID: key, genres: genres, years: years, calibration: calibration)
            // Collaborative signal: the seed artist's global fan graph (cached).
            let related = category == .artist ? await relatedArtistWeights(for: radio.artist) : [:]
            let pool = await Task.detached {
                Self.buildPlaylistCandidates(
                    seedIds: seedIds, lib: lib, index: index,
                    genres: genres, disliked: disliked,
                    daySeed: "\(stamp)|\(key)", limit: Self.artistRadioPoolLimit,
                    likedKeys: liked, knownArtists: known, adventurousness: adv, hardBan: hardBan,
                    tasteVector: taste, relatedArtists: related, gate: gate)
            }.value
            guard !pool.isEmpty else { continue }

            // For non-artist categories there's no single "seed artist" to anchor —
            // cap every artist equally so the station spreads across the bucket.
            let capped = Self.capForPlaylist(
                pool, seedArtist: category == .artist ? radio.artist : "",
                minTracks: Self.artistRadioMinTracks,
                maxTracks: Self.artistRadioMaxTracks,
                maxPerArtist: Self.artistRadioMaxPerArtist,
                seedCap: category == .artist ? Self.artistRadioSeedCap : Self.artistRadioMaxPerArtist)
            guard capped.count >= 2 else { continue }

            // Flow-sequence the final 20–30 into an arc so the Qobuz playlist plays
            // like a designed set, not a relevance dump. `.peak` rises to a mid-set
            // high then eases — the right shape for a bounded saved playlist (vs the
            // endless in-app radio's `.smooth`). For an ARTIST station we open on the
            // seed artist's most energetic track so the playlist's identity is clear
            // from track one. Needs embeddings (resolve the capped TrackRecords back
            // to their SonicTracks).
            let tracks: [TrackRecord]
            if index != nil {
                let sts = capped.compactMap { byId[$0.id] }
                if sts.count == capped.count {
                    let preferredStart: Set<String> = category == .artist
                        ? Set(sts.filter { ($0.artist ?? "").lowercased() == radio.artist.lowercased() }.map(\.id))
                        : []
                    tracks = RadioSequencer.order(sts, preferredStartIds: preferredStart, arc: .peak).map {
                        TrackRecord(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album)
                    }
                } else { tracks = capped }
            } else { tracks = capped }

            let sonics = tracks.compactMap { byId[$0.id] }
            let profile = Self.sonicProfileSummary(sonics, includeAttributes: radioAttributesEnabled,
                                                   calibration: calibration)
            let meta = await aiTitleAndDescription(for: radio, category: category, sample: tracks,
                                                   profile: profile, sonics: sonics, calibration: calibration)
            out.append(SonicRadioPlaylist(
                id: key, artist: radio.artist, title: meta.title, description: meta.description,
                imageKey: radio.imageKey, tracks: tracks,
                qobuzPlaylistID: UserDefaults.standard.string(forKey: Self.qobuzIDKey(key))))
        }
        Log.info("Radio's (\(category.rawValue)) gebouwd: \(out.count) playlists (van \(radios.count) seeds, \(lib.count) geanalyseerde tracks)", category: .roon)
        return out
    }

    /// The stable artist seed radios (top-played anchors + max-spread discovery),
    /// persisting the chosen seed keys so every refresh updates the same playlists.
    /// (Internal, not file-private, so the radio-sync settings can enumerate them.)
    func artistSeedRadios(
        db: DatabaseManager, lib: [DatabaseManager.SonicTrack],
        index: VectorIndex?, disliked: Set<String>, stamp: String
    ) async -> [SonicRadio] {
        // Top artists by listening history (server reads local DB; client fetches /history).
        let topArtistKeys: [String]
        if isRemote {
            let snap = await tasteProfile(topLimit: 100, recentLimit: 1)
            topArtistKeys = (snap?.topArtists ?? []).map { $0.artist.lowercased() }
        } else {
            topArtistKeys = ((try? await db.topArtistsListened(limit: 100)) ?? []).map { $0.artist.lowercased() }
        }

        // Group analyzed tracks by lowercased artist.
        let byArtist = lib.reduce(into: [String: [DatabaseManager.SonicTrack]]()) { dict, t in
            guard let a = t.artist, !a.isEmpty else { return }
            dict[a.lowercased(), default: []].append(t)
        }

        // Reuse the PERSISTED seeds so identity is stable across refreshes; only
        // refill slots whose seed no longer qualifies. First run (no persisted
        // seeds) uses the original 2 top-played + 4 max-spread discovery pick.
        func qualifies(_ key: String) -> Bool { (byArtist[key]?.count ?? 0) >= Self.radioMinTracks }
        let kept = Self.loadSeedKeys().filter(qualifies)
        let seedKeys: [String]
        if kept.count >= Self.artistRadioCount {
            seedKeys = Array(kept.prefix(Self.artistRadioCount))
        } else {
            let pinned      = kept.isEmpty ? topArtistKeys : kept
            let pinnedCount = kept.isEmpty ? Self.artistRadioTopCount : kept.count
            seedKeys = await Task.detached {
                Self.maxSpreadArtistKeys(
                    byArtist: byArtist, index: index,
                    topArtistKeys: pinned, daySeed: stamp,
                    count: Self.artistRadioCount, topCount: pinnedCount)
            }.value
        }
        guard !seedKeys.isEmpty else { return [] }
        Self.saveSeedKeys(seedKeys)

        // Explicitly-selected artist radios that AREN'T among the 6 auto-seeds must
        // still be built — otherwise ticking "artist:kathleenbattle" in the sync
        // settings silently never mirrors it (the "18/21" gap). Union them in
        // (qualifying only); they don't displace or get persisted as auto-seeds.
        var allKeys = seedKeys
        if let selection = radioSyncSelection {
            let selectedArtistKeys = selection
                .filter { $0.hasPrefix("artist:") }
                .map { String($0.dropFirst("artist:".count)) }
                .filter { qualifies($0) && !allKeys.contains($0) }
            allKeys.append(contentsOf: selectedArtistKeys)
        }

        return allKeys.compactMap { key in
            guard let tracks = byArtist[key], !tracks.isEmpty else { return nil }
            let display = tracks.first(where: { !($0.artist?.isEmpty ?? true) })?.artist ?? key
            let img = tracks.first(where: { $0.imageKey?.isEmpty == false })?.imageKey
            let seeds = tracks.filter { !disliked.contains($0.matchKey) }.prefix(Self.radioMaxSeeds)
            guard seeds.count >= Self.radioMinTracks else { return nil }
            return SonicRadio(id: "artist:\(key)", artist: display, imageKey: img,
                              trackCount: seeds.count, seedIds: seeds.map(\.id))
        }
    }

    // MARK: Max-spread seed selection

    /// Chooses `count` seed artist keys for the Qobuz playlists.
    ///
    /// The first `topCount` keys are the most-played qualifying artists (familiar
    /// anchors). The remaining `count − topCount` are picked by farthest-first
    /// max-spread over artist centroids in the CLAP embedding space, ensuring
    /// the 6 playlists cover maximally different sonic regions.
    ///
    /// `daySeed` breaks centroid-distance ties differently each day so the
    /// discovery selection shifts gradually, without the spread collapsing.
    nonisolated static func maxSpreadArtistKeys(
        byArtist: [String: [DatabaseManager.SonicTrack]],
        index: VectorIndex?,
        topArtistKeys: [String],
        daySeed: String,
        count: Int,
        topCount: Int
    ) -> [String] {
        let qualifying = byArtist.filter { $0.value.count >= radioMinTracks }
        guard !qualifying.isEmpty else { return [] }

        let fixedKeys = topArtistKeys.filter { qualifying[$0] != nil }.prefix(topCount).map { $0 }
        let fixedSet  = Set(fixedKeys)

        guard let idx = index else {
            // No embedding index — fall back to top-played order.
            return Array(topArtistKeys.filter { qualifying[$0] != nil }.prefix(count))
        }

        // Compute L2-normalized centroid per qualifying artist.
        struct ArtistCentroid {
            let key: String
            let centroid: [Float]
        }
        var allCentroids: [ArtistCentroid] = []
        allCentroids.reserveCapacity(qualifying.count)
        for (key, tracks) in qualifying {
            if let c = idx.centroid(ofIds: tracks.map(\.id)) {
                allCentroids.append(ArtistCentroid(key: key, centroid: c))
            }
        }

        // Fixed seeds are the already-selected centroids.
        var selected = allCentroids.filter { fixedSet.contains($0.key) }
        // Remaining candidates: daily-shuffled so ties break differently each day.
        var candidates = dailyShuffled(
            allCentroids.filter { !fixedSet.contains($0.key) },
            seed: daySeed)

        // Farthest-first: add the candidate whose centroid is maximally far from
        // every already-selected centroid (cosine distance = 1 − dot product).
        var picks: [String] = fixedKeys
        let dim = allCentroids.first?.centroid.count ?? 0

        for _ in 0..<(count - fixedKeys.count) {
            guard !candidates.isEmpty else { break }

            if selected.isEmpty || dim == 0 {
                picks.append(candidates.removeFirst().key)
                continue
            }
            var bestIdx = 0
            var bestMinDist: Float = -Float.infinity
            for (i, cand) in candidates.enumerated() {
                var minDist = Float.infinity
                for sel in selected {
                    var d: Float = 0
                    vDSP_dotpr(cand.centroid, 1, sel.centroid, 1, &d,
                               vDSP_Length(min(cand.centroid.count, sel.centroid.count)))
                    let dist = 1 - d   // cosine distance (higher = more different)
                    if dist < minDist { minDist = dist }
                }
                if minDist > bestMinDist { bestMinDist = minDist; bestIdx = i }
            }
            let next = candidates.remove(at: bestIdx)
            picks.append(next.key)
            selected.append(next)
        }
        return picks
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
        func cap(for artist: String) -> Int { artist == seedKey ? seedCap : maxPerArtist }

        // Group the (relevance-ordered) pool by artist, preserving within-artist
        // order and each artist's first-appearance position. The pool arrives
        // MMR-diversified; iterating it straight through and capping per-artist
        // would re-cluster it (two A tracks, then a B), undoing that work. So we
        // round-robin across artists instead — one track from each before any
        // artist's second — which both honours the cap and keeps the selection
        // spread. The set is flow-sequenced afterwards, so only WHICH tracks are
        // chosen matters here, not their order.
        var groups: [String: [TrackRecord]] = [:]
        var artistOrder: [String] = []
        for t in pool {
            let a = (t.artist ?? "").lowercased()
            if groups[a] == nil { groups[a] = []; artistOrder.append(a) }
            groups[a]?.append(t)
        }

        var cursor: [String: Int] = [:]
        var perArtist: [String: Int] = [:]
        var seenTitles = Set<String>()   // collapse "song", "song (Remix)", "song (feat…)"
        var pickedIds = Set<String>()
        var picked: [TrackRecord] = []

        roundRobin: while picked.count < maxTracks {
            var progressed = false
            for a in artistOrder {
                if picked.count >= maxTracks { break roundRobin }
                guard perArtist[a, default: 0] < cap(for: a) else { continue }
                guard let tracks = groups[a] else { continue }
                // Take this artist's next track that isn't a near-duplicate version.
                var i = cursor[a, default: 0]
                while i < tracks.count {
                    let t = tracks[i]; i += 1
                    let titleKey = "\(a)|\(titleDedupKey(t.title))"
                    if seenTitles.contains(titleKey) { continue }   // dup version → skip
                    perArtist[a, default: 0] += 1
                    seenTitles.insert(titleKey)
                    pickedIds.insert(t.id)
                    picked.append(t)
                    progressed = true
                    break
                }
                cursor[a] = i
            }
            if !progressed { break }   // a full sweep added nothing → exhausted
        }

        // Top up to minTracks from what the per-artist caps left behind, in
        // relevance (pool) order, still collapsing duplicate versions.
        if picked.count < minTracks {
            for t in pool {
                if picked.count >= min(minTracks, maxTracks) { break }
                if pickedIds.contains(t.id) { continue }
                let titleKey = "\((t.artist ?? "").lowercased())|\(titleDedupKey(t.title))"
                if seenTitles.insert(titleKey).inserted {
                    pickedIds.insert(t.id)
                    picked.append(t)
                }
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

    /// Candidate list for a coherent artist PLAYLIST. The seed artist's own
    /// tracks lead; then the k-NN sonic neighbours follow (genre-layered: in-genre
    /// first, off-genre after). A `daySeed` shuffles the neighbours portion so the
    /// 20–30 tracks picked by `capForPlaylist` rotate daily while staying within
    /// the same ~200-track sonically-close pool. Pass `""` for a stable (test)
    /// order.
    nonisolated static func buildPlaylistCandidates(
        seedIds: [String], lib: [DatabaseManager.SonicTrack], index: VectorIndex?,
        genres: [String: Set<String>] = [:], disliked: Set<String> = [],
        daySeed: String = "", limit: Int = 500,
        likedKeys: Set<String> = [], knownArtists: Set<String> = [],
        adventurousness: Double = defaultAdventurousness, hardBan: Bool = false,
        tasteVector: [Float]? = nil,
        relatedArtists: [String: Double] = [:],
        gate: (@Sendable (DatabaseManager.SonicTrack) -> Bool)? = nil
    ) -> [TrackRecord] {
        let seedSet = Set(seedIds)
        // Don't seed on a disliked track.
        let own = lib.filter { seedSet.contains($0.id) && !disliked.contains($0.matchKey) }
        guard !own.isEmpty else { return [] }
        let salt = daySeed.isEmpty ? "playlist" : daySeed

        // Smart path (embeddings present): RadioEngine relevance + dial + MMR. The
        // daily salt rotates the selection, so no extra shuffle. The genre layering
        // below and `capForPlaylist` then shape it into a 20–30 track playlist;
        // `buildRadioPlaylists` flow-sequences the final set. Rule-based fallback
        // keeps the original nearest + daily-shuffle behaviour.
        let useEmb = index != nil && own.contains { index!.embedding(forId: $0.id) != nil }
        var neighbours: [DatabaseManager.SonicTrack]
        if useEmb, let index {
            let opts = RadioEngine.Options(
                adventurousness: adventurousness, poolLimit: limit,
                hardBanDisliked: hardBan, sequence: false)
            let ranked = RadioEngine.rank(
                seeds: own, library: lib, index: index, options: opts,
                disliked: disliked, likedKeys: likedKeys, knownArtists: knownArtists,
                tasteVector: tasteVector, relatedArtists: relatedArtists, salt: salt)
            neighbours = applyFeedbackWeighting(
                ranked.map(\.track), disliked: disliked, salt: salt, matchKey: { $0.matchKey })
        } else {
            // Disliked tracks aren't banned — down-sample them (much less often).
            neighbours = applyFeedbackWeighting(
                SonicEngine.nearest(toSeeds: own, in: lib, limit: limit, index: index).map(\.track),
                disliked: disliked, salt: salt, matchKey: { $0.matchKey })
            // Daily variety: shuffle the neighbour pool so different (but equally
            // sonically close) tracks surface each day. The seed artist's own tracks
            // are kept at the front and are unaffected.
            if !daySeed.isEmpty { neighbours = dailyShuffled(neighbours, seed: daySeed) }
        }

        // Feature fusion: keep the pool true to the bucket's defining measured
        // constraint (activity energy/tempo, mood, genre, decade). Relaxes when
        // the matching pool alone can't fill a playlist.
        if let gate {
            neighbours = gatedWithRelaxation(neighbours, gate: gate,
                                             minKeep: artistRadioMaxTracks * 2)
        }

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
            // In-genre neighbours lead; off-genre fill remaining slots. Both
            // halves are already day-shuffled so they rotate within their tier.
            ordered = own + neighbours.filter(sharesGenre) + neighbours.filter { !sharesGenre($0) }
        }

        // Dedup by CONTENT, not Roon id — the same song can have several library
        // rows (different albums) with one match_key.
        var seen = Set<String>()
        var deduped: [DatabaseManager.SonicTrack] = []
        for t in ordered {
            let key = t.matchKey.isEmpty ? t.id : t.matchKey
            if seen.insert(key).inserted { deduped.append(t) }
        }
        return deduped.map { TrackRecord(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) }
    }

    // MARK: AI title + description

    // `v2`: the prompt now steers titles toward the sonic profile (genre / mood
    // / energy) instead of abstract wordplay. Bumping the key regenerates the
    // earlier vague titles on next build.
    private static func titleKey(_ id: String) -> String  { "artistradio.title.v2.\(id)" }
    private static func descKey(_ id: String) -> String   { "artistradio.desc.v2.\(id)" }
    private static func descSigKey(_ id: String) -> String { "artistradio.descsig.v2.\(id)" }
    /// The sonic-profile signature the cached TITLE was generated for. When the
    /// station's measured character drifts past this band-fingerprint, the title
    /// is regenerated (and the Qobuz playlist renamed IN PLACE via its stored id)
    /// — the fix for names frozen on a long-gone first-build selection.
    private static func titleSigKey(_ id: String) -> String { "artistradio.titlesig.v1.\(id)" }
    static func qobuzIDKey(_ id: String) -> String        { "artistradio.qobuzid.\(id)" }

    /// A stable signature of a track selection (content, order-independent) used to
    /// detect when a radio's tracklist actually changed, so the description can be
    /// regenerated to match while the title (the Qobuz identity) stays cached.
    nonisolated static func trackSetSignature(_ tracks: [TrackRecord]) -> String {
        let joined = tracks.map { "\(($0.artist ?? "").lowercased())|\($0.title.lowercased())" }
            .sorted().joined(separator: "\u{1f}")
        return String(seed64(joined))
    }

    /// Cached AI title/description for a radio, generating + persisting them on
    /// first use. `profile` is the sonic-profile summary used to steer the title;
    /// `sonics` the resolved selection (for claim validation + the profile
    /// signature).
    ///
    /// The title is cached, but no longer frozen forever: it's reused only while
    /// the selection's *profile signature* (coarse sonic bands — insensitive to
    /// the daily rotation) still matches the one it was generated for. When the
    /// station's sound drifts, the title regenerates and the Qobuz playlist is
    /// renamed in place via its stored playlist id. The description regenerates
    /// on any real tracklist change, as before.
    func aiTitleAndDescription(for radio: SonicRadio, category: RadioCategory, sample: [TrackRecord],
                               profile: String, sonics: [DatabaseManager.SonicTrack] = [],
                               calibration: TitleGrounding.Calibration? = nil) async -> (title: String, description: String) {
        let d = UserDefaults.standard
        let fallback = Self.fallbackMeta(category: category, label: radio.artist)
        let cachedTitle = d.string(forKey: Self.titleKey(radio.id))
        let cachedDesc = d.string(forKey: Self.descKey(radio.id))
        let hasRealTitle = (cachedTitle?.isEmpty == false) && cachedTitle != fallback.title
        let sig = Self.trackSetSignature(sample)
        let profileSig = TitleGrounding.profileSignature(sonics)

        // A cached *real* title is reused while it still matches the station's
        // measured character (profile signature). A missing stored signature —
        // every radio titled before this mechanism existed — counts as stale, so
        // legacy titles regenerate once against real measurements. A cached bare
        // fallback title is NOT trusted — it means an earlier LLM call failed
        // (e.g. Ollama cold-start) — so we retry generation now.
        let titleFresh = hasRealTitle && d.string(forKey: Self.titleSigKey(radio.id)) == profileSig
        let descFresh = d.string(forKey: Self.descSigKey(radio.id)) == sig
        if titleFresh, let t = cachedTitle, let desc = cachedDesc, !desc.isEmpty, descFresh {
            return (t, desc)
        }
        let stats = sonics.isEmpty ? nil : TitleGrounding.SelectionStats.compute(sonics)
        if let meta = await Self.generateAIMeta(category: category, label: radio.artist,
                                                sample: sample, profile: profile, stats: stats,
                                                calibration: calibration) {
            // A still-fresh title is kept (only the desc needed refreshing); a
            // stale or missing one takes the newly generated title.
            let title = titleFresh ? (cachedTitle ?? meta.title) : meta.title
            d.set(title, forKey: Self.titleKey(radio.id))
            d.set(meta.description, forKey: Self.descKey(radio.id))
            d.set(sig, forKey: Self.descSigKey(radio.id))
            d.set(profileSig, forKey: Self.titleSigKey(radio.id))
            return (title, meta.description)
        }
        // LLM unavailable this round — reuse whatever we have, else the fallback.
        // Don't cache the fallback (so a later build retries). The stored profile
        // signature is left untouched, so the regeneration retries too.
        return (hasRealTitle ? (cachedTitle ?? fallback.title) : fallback.title,
                (cachedDesc?.isEmpty == false) ? cachedDesc! : fallback.description)
    }

    /// A compact Dutch summary of the selection's sonic character — dominant
    /// tags/genres, top moods, energy band and tempo — fed to the title prompt so
    /// titles describe *what kind of music* it is, not just a clever phrase.
    ///
    /// `calibration` (the library's attribute distribution) makes the attribute
    /// descriptors library-relative: "akoestisch" only when the selection is both
    /// absolutely acoustic-leaning AND in this library's upper acoustic reaches —
    /// so a mis-scaled zero-shot axis can't put a false claim in the prompt.
    nonisolated static func sonicProfileSummary(_ tracks: [DatabaseManager.SonicTrack],
                                                includeAttributes: Bool = false,
                                                calibration: TitleGrounding.Calibration? = nil) -> String {
        guard !tracks.isEmpty else { return "" }
        var parts: [String] = []

        // CLAP attribute axes: average the per-track scores and name the ones
        // that clearly lean one way (calibrated against the library when
        // possible), so the AI title can reflect e.g. a danceable, acoustic, or
        // instrumental character.
        if includeAttributes {
            var sum: [String: Float] = [:]; var cnt: [String: Int] = [:]
            for t in tracks { for (k, v) in t.attributes { sum[k, default: 0] += v; cnt[k, default: 0] += 1 } }
            var attrParts: [String] = []
            for axis in ["valence", "danceability", "acousticness", "instrumentalness"] {
                guard let c = cnt[axis], c > 0 else { continue }
                if let word = TitleGrounding.band(axis: axis, selectionAvg: sum[axis]! / Float(c),
                                                  calibration: calibration) {
                    attrParts.append(word)
                }
            }
            if !attrParts.isEmpty { parts.append("kenmerken: \(attrParts.joined(separator: ", "))") }
        }

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

        // Energy band on the perceptual energy signal (arousal-or-RMS), judged
        // LIBRARY-RELATIVE when calibrated — so a compressed RMS axis still yields
        // an honest "rustig/gemiddeld/energiek" (bottom/middle/top third of this
        // library) instead of everything reading "rustig".
        let energies = tracks.compactMap(TitleGrounding.energySignal)
        if !energies.isEmpty {
            let avg = energies.reduce(0, +) / Double(energies.count)
            let band: String
            if let pct = calibration?.percentile(of: Float(avg), axis: TitleGrounding.energyAxis) {
                band = pct < 0.34 ? "rustig" : (pct < 0.67 ? "gemiddeld" : "energiek")
            } else {
                band = avg < 0.4 ? "rustig" : (avg < 0.7 ? "gemiddeld" : "energiek")
            }
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

    /// The tidy default title/description used when the LLM can't produce one,
    /// phrased per category. For `.artist` the title is exactly "Radio rond X" so
    /// the cached-fallback detection in `aiTitleAndDescription` keeps working.
    nonisolated static func fallbackMeta(category: RadioCategory, label: String) -> (title: String, description: String) {
        switch category {
        case .artist:
            return ("Radio rond \(label)",
                    "Een eindeloze radio rond \(label) en muzikaal verwante artiesten uit je bibliotheek.")
        case .genre:
            return ("\(label)-radio",
                    "Een eindeloze radio vol \(label) uit je bibliotheek.")
        case .mood:
            return ("Sfeer: \(label)",
                    "Een eindeloze radio rond de sfeer ‘\(label.lowercased())’ uit je bibliotheek.")
        case .activity:
            return (label,
                    "Een eindeloze radio voor \(label.lowercased()) uit je bibliotheek.")
        case .decade:
            return (label,
                    "Een eindeloze radio met muziek uit de \(label.lowercased()) uit je bibliotheek.")
        case .sonic:
            return (label,
                    "Een eindeloze radio rond de sonische buurt ‘\(label)’ — tracks die op klank bij elkaar horen.")
        }
    }

    /// Ask the configured LLM for a Dutch title that names the sonic profile +
    /// a short description, as strict JSON. Returns nil when the LLM call fails
    /// (e.g. an Ollama cold-start timeout) or returns nothing usable — the caller
    /// then uses a temporary fallback WITHOUT caching it, so a later build retries
    /// instead of freezing the default name forever.
    ///
    /// `stats` (when available) grounds the result: a title claiming a style the
    /// measurements contradict ("akoestisch" on an electronic selection) gets ONE
    /// corrective retry naming the offending words; a second violation fails the
    /// call. This is what makes "RoonSage · Acoustic" on non-acoustic music
    /// impossible rather than merely unlikely.
    nonisolated static func generateAIMeta(category: RadioCategory, label: String, sample: [TrackRecord],
                                           profile: String, stats: TitleGrounding.SelectionStats? = nil,
                                           calibration: TitleGrounding.Calibration? = nil) async -> (title: String, description: String)? {
        let fallback = fallbackMeta(category: category, label: label)
        let fallbackTitle = fallback.title
        let fallbackDesc  = fallback.description

        // What the station is built around, phrased per category for the prompt.
        let subject: String
        switch category {
        case .artist:   subject = "rond de artiest \"\(label)\""
        case .genre:    subject = "rond het genre \"\(label)\""
        case .mood:     subject = "met de sfeer \"\(label)\""
        case .activity: subject = "voor de activiteit \"\(label)\""
        case .decade:   subject = "met muziek uit de \(label.lowercased())"
        case .sonic:    subject = "rond de sonische buurt \"\(label)\""
        }

        let examples = sample.prefix(8)
            .map { "• \($0.title) — \($0.artist ?? "onbekend")" }
            .joined(separator: "\n")
        let others = Array(Set(sample.compactMap { $0.artist }
            .filter { $0.lowercased() != label.lowercased() }))
            .prefix(6).joined(separator: ", ")

        let system = """
        Je bent een muziekredacteur die pakkende, INFORMATIEVE Nederlandse playlist-titels schrijft. \
        Antwoord UITSLUITEND met strikt geldige JSON, exact in de vorm \
        {"title": "...", "description": "..."}. Geen uitleg, geen markdown, geen codeblok.
        """
        let user = """
        Maak een titel en korte beschrijving voor een radio-playlist \(subject).

        Sonisch profiel van de selectie (GEMETEN uit de audio): \(profile.isEmpty ? "onbekend" : profile)
        Voorbeeldtracks:
        \(examples)
        Kenmerkende artiesten: \(others.isEmpty ? "diverse" : others)

        Eisen voor "title":
        - Maak METEEN duidelijk wat voor muziek/sfeer het is: noem het genre/stijl en/of de sfeer of energie (bv. "Melodieuze indie-rock", "Dromerige akoestische avond", "Energieke house").
        - Baseer stijl- en sfeerwoorden UITSLUITEND op het gemeten sonische profiel hierboven. Beweer GEEN kenmerken (akoestisch, dansbaar, rustig, …) die er niet in staan.
        - Sluit aan op het thema \(subject). Vermijd vage woordgrappen die het genre niet verraden.
        - Gebruik UITSLUITEND bestaande, correct gespelde Nederlandse woorden (Engelse genrenamen mogen). Verzin GEEN woorden.
        - Kort en krachtig: MAX 45 tekens, het liefst korter.

        Eisen voor "description":
        - 1 à 2 korte zinnen, vlot en correct Nederlands. Beschrijf de stijl/sfeer en noem een paar kenmerkende artiesten of het genre. Verzin geen woorden.
        """

        let config = LLMConfigStore.load()

        /// One LLM round → parsed meta, or nil on failure/parse-fallback.
        func attempt(_ userPrompt: String) async -> (title: String, description: String)? {
            let raw: String
            do {
                // jsonMode + a low-but-not-flat temperature: faithful to the
                // measured profile, still varied enough to not template.
                raw = try await LLMClient.shared.complete(system: system, user: userPrompt, config: config,
                                                          jsonMode: true, temperature: 0.35)
            } catch {
                Log.warning("AI radio-titel mislukt voor '\(label)': \(error.localizedDescription) — tijdelijke standaardtitel, wordt later opnieuw geprobeerd", category: .network)
                return nil
            }
            let meta = parseTitleJSON(raw, fallbackTitle: fallbackTitle, fallbackDesc: fallbackDesc)
            // The LLM answered but produced no usable title (parse fell all the way
            // back). Treat as failure so it isn't cached and freezes the default.
            guard meta.title != fallbackTitle else {
                Log.warning("AI radio-titel onbruikbaar voor '\(label)' (parse-fallback) — niet gecachet", category: .network)
                return nil
            }
            return meta
        }

        guard let meta = await attempt(user) else { return nil }
        guard let stats else { return meta }

        // Grounding gate: reject a title whose style claims the measurements
        // contradict; give the model one corrective retry naming the offenders.
        let bad = TitleGrounding.violations(title: meta.title, stats: stats, calibration: calibration)
        guard !bad.isEmpty else { return meta }
        Log.info("AI radio-titel '\(meta.title)' voor '\(label)' spreekt de metingen tegen (\(bad.joined(separator: "; "))) — corrigerende poging", category: .network)
        let corrective = user + """


        LET OP — je eerdere titel "\(meta.title)" bevatte claims die de metingen tegenspreken: \(bad.joined(separator: "; ")). \
        Maak een nieuwe titel ZONDER deze woorden, trouw aan het gemeten profiel.
        """
        guard let retry = await attempt(corrective),
              TitleGrounding.violations(title: retry.title, stats: stats, calibration: calibration).isEmpty else {
            Log.warning("AI radio-titel voor '\(label)' blijft de metingen tegenspreken — tijdelijke standaardtitel, wordt later opnieuw geprobeerd", category: .network)
            return nil
        }
        return retry
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

    /// Back-compat wrapper: sync the artist category to Qobuz.
    @discardableResult
    public func syncArtistRadiosToQobuz() async -> Int {
        await syncRadiosToQobuz(category: .artist)
    }

    /// Build the AI radios for `category` and mirror each to its stable Qobuz
    /// playlist (find-or-create by name, replace contents, push AI description).
    /// Returns the number of playlists successfully synced. Surfaces a toast (and
    /// returns 0) when Qobuz isn't configured or there's nothing to build.
    ///
    /// `restrictKeys` narrows the buckets (daypart auto-sync). `reconcile` runs the
    /// orphan cleanup keeping ALL categories — used by the manual button so syncing
    /// one category never deletes another's playlists. The daypart auto-sync passes
    /// `reconcile: false` and runs a single scoped reconciliation itself.
    ///
    /// `restrictIDs` (optional) narrows the built playlists to exactly those radio
    /// ids before syncing — used by the per-radio selection so artist radios (which
    /// ignore `restrictKeys`) can also be filtered down to the chosen ones.
    @discardableResult
    public func syncRadiosToQobuz(category: RadioCategory, restrictKeys: [String]? = nil, restrictIDs: Set<String>? = nil, reconcile: Bool = true, forceReplace: Bool = false) async -> Int {
        guard let email = KeychainStore.load(key: "qobuz_email"), !email.isEmpty,
              let pw = KeychainStore.load(key: "qobuz_password"), !pw.isEmpty else {
            reportError("Qobuz is niet ingesteld — vul je inloggegevens in bij Instellingen.")
            return 0
        }
        var playlists = await buildRadioPlaylists(category: category, restrictKeys: restrictKeys)
        if let restrictIDs { playlists = playlists.filter { restrictIDs.contains($0.id) } }
        guard !playlists.isEmpty else {
            reportError("Geen \(category.label.lowercased())-radio's om te synchroniseren — analyseer eerst meer muziek.")
            return 0
        }

        var synced = 0
        for pl in playlists {
            let name = pl.qobuzName
            let pairs = pl.tracks.map { (title: $0.title, artist: $0.artist, album: $0.album) }
            // Pass the previously-stored Qobuz id so a changed title renames the
            // existing playlist in place instead of orphaning it (a freshly
            // generated AI title replaces an earlier fallback).
            let knownID = UserDefaults.standard.string(forKey: Self.qobuzIDKey(pl.id))
            if let result = await QobuzClient.shared.syncPlaylist(
                name: name, description: pl.description, tracks: pairs, email: email, password: pw,
                knownPlaylistID: knownID, forceReplace: forceReplace) {
                UserDefaults.standard.set(result.playlistID, forKey: Self.qobuzIDKey(pl.id))
                synced += 1
                Log.info("AI radio (\(category.rawValue)) gesynct naar Qobuz: '\(name)' (\(result.matched)/\(result.total) tracks)",
                         category: .network)
            } else {
                // nil ≠ login failure: it's also a deliberate skip — 0 tracks
                // resolved, or the catastrophic-shrink guard kept the existing
                // playlist intact. Don't assert a hard failure.
                Log.warning("AI radio (\(category.rawValue)) sync overgeslagen of mislukt voor '\(name)' (geen match, beschermd, of Qobuz-fout)",
                            category: .network)
            }
        }
        // Cache the per-category set so /artist-radios serves it to clients AND so
        // reconciliation keeps the right playlists. Crucially this runs even when
        // `synced == 0`: a radio the shrink-guard left intact returns nil (not
        // counted as synced), but its playlist is STILL live on Qobuz — keep only
        // entries with a persisted Qobuz id so their name reaches the reconcile
        // keep-set (else the orphan sweep would delete the very playlist we
        // protected) while never caching a playlist that was never created.
        let refreshed: [SonicRadioPlaylist] = playlists.compactMap { pl in
            guard let qid = UserDefaults.standard.string(forKey: Self.qobuzIDKey(pl.id)) else { return nil }
            var p = pl
            p.qobuzPlaylistID = qid
            return p
        }
        if !refreshed.isEmpty {
            cachedArtistRadios[category.rawValue] = refreshed
        }

        // Manual sync: keep every category's playlists (scoped reconcile = nil).
        if reconcile {
            await reconcileQobuzRadios(keepCategories: nil, email: email, password: pw)
        }
        return synced
    }

    /// Reconcile the "RoonSage · …" playlists on Qobuz back to a keep-set.
    ///
    /// `keepCategories == nil` keeps every category (manual sync — never deletes a
    /// category you didn't touch). A non-nil set keeps ONLY those categories and
    /// removes the rest — this is how the daypart auto-sync rotates: only artist +
    /// the current daypart's category stay mirrored; the others are deleted (and
    /// their stale Qobuz ids cleared) until their daypart comes round again. Cached
    /// AI titles are kept, so a returning category reuses its stable name.
    func reconcileQobuzRadios(keepCategories: Set<RadioCategory>?, email: String, password: String) async {
        let keepCats = keepCategories ?? Set(RadioCategory.allCases)
        var keepNames = Set<String>()
        var keepIds = Set<String>()
        for cat in keepCats {
            let ids = Self.liveRadioIDs(cat)
            keepIds.formUnion(ids)
            // Names we last synced for this category (covers fallback-titled radios
            // whose title isn't cached) plus the cached AI title of each live id.
            keepNames.formUnion((cachedArtistRadios[cat.rawValue] ?? []).map(\.qobuzName))
            for id in ids {
                if let t = UserDefaults.standard.string(forKey: Self.titleKey(id)), !t.isEmpty {
                    keepNames.insert(Self.qobuzPlaylistName(for: t))
                }
            }
        }
        // The known Qobuz ids of the kept radios: a rename-in-place that failed
        // mid-sync leaves the old name live — protect it by id, not just name.
        let keepQobuzIDs = Set(keepIds.compactMap { UserDefaults.standard.string(forKey: Self.qobuzIDKey($0)) })
        let removed = await QobuzClient.shared.deleteRadioOrphans(
            keep: keepNames, keepIDs: keepQobuzIDs, namePrefix: Self.qobuzNamePrefix, email: email, password: password)
        if removed > 0 {
            Log.info("AI radio's: \(removed) verouderde/uit-dagdeel playlist(s) van Qobuz opgeruimd", category: .network)
        }
        // Forget the Qobuz ids of every radio NOT kept (their playlists are gone),
        // and drop the now-stale cached set so client apps don't show vanished
        // playlists. Titles are intentionally preserved for stable names on return.
        Self.clearQobuzIDs(notIn: keepIds)
        for cat in RadioCategory.allCases where !keepCats.contains(cat) {
            cachedArtistRadios[cat.rawValue] = []
        }
    }

    /// Reconcile the "RoonSage · …" playlists on Qobuz to EXACTLY `keepIDs` — used by
    /// the per-radio selection sync. Every RoonSage playlist whose radio id isn't in
    /// the set is removed; cached AI titles are preserved so a re-selected radio
    /// reuses its stable name.
    func reconcileQobuzRadios(keepIDs: Set<String>, email: String, password: String) async {
        var keepNames = Set<String>()
        for id in keepIDs {
            if let t = UserDefaults.standard.string(forKey: Self.titleKey(id)), !t.isEmpty {
                keepNames.insert(Self.qobuzPlaylistName(for: t))
            }
        }
        // Names from the freshly-cached sync set (covers fallback-titled radios).
        for (_, pls) in cachedArtistRadios {
            for pl in pls where keepIDs.contains(pl.id) { keepNames.insert(pl.qobuzName) }
        }
        // Protect kept radios by their known Qobuz id too (rename-in-place safety).
        let keepQobuzIDs = Set(keepIDs.compactMap { UserDefaults.standard.string(forKey: Self.qobuzIDKey($0)) })
        let removed = await QobuzClient.shared.deleteRadioOrphans(
            keep: keepNames, keepIDs: keepQobuzIDs, namePrefix: Self.qobuzNamePrefix, email: email, password: password)
        if removed > 0 {
            Log.info("AI radio's: \(removed) niet-geselecteerde playlist(s) van Qobuz opgeruimd", category: .network)
        }
        Self.clearQobuzIDs(notIn: keepIDs)
        for cat in RadioCategory.allCases {
            cachedArtistRadios[cat.rawValue] = (cachedArtistRadios[cat.rawValue] ?? []).filter { keepIDs.contains($0.id) }
        }
    }

    /// The persisted radio ids currently considered live for one category.
    static func liveRadioIDs(_ category: RadioCategory) -> Set<String> {
        category == .artist ? Set(loadSeedKeys().map { "artist:\($0)" }) : Set(loadRadioIDs(category))
    }

    /// Forget the cached Qobuz playlist id of every radio whose id is NOT in
    /// `keepIds`, so a returning radio creates a fresh playlist instead of trying to
    /// update a deleted one. The AI title/description caches are left intact.
    static func clearQobuzIDs(notIn keepIds: Set<String>) {
        let d = UserDefaults.standard
        let prefix = "artistradio.qobuzid."
        for key in d.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            let id = String(key.dropFirst(prefix.count))
            if !keepIds.contains(id) { d.removeObject(forKey: qobuzIDKey(id)) }
        }
    }

    /// JSON-encode the cached radio set for `category` for the share server's
    /// /artist-radios endpoint.
    ///
    /// `cachedArtistRadios` is an in-memory side-effect of the last sync, so it's
    /// empty after a server restart (until the first auto-sync) and for any
    /// category the daypart rotation has reconciled away — leaving client apps
    /// with "nog geen radio's" even though the playlists are live on Qobuz. When
    /// the cache is empty we rebuild from persisted state: cached AI titles and
    /// the stored Qobuz ids make `buildRadioPlaylists` reconstruct the same set,
    /// so the endpoint always reflects what the server mirrored.
    public func artistRadiosData(category: RadioCategory = .artist) async -> Data {
        var radios = cachedArtistRadios[category.rawValue] ?? []
        if radios.isEmpty {
            radios = await buildRadioPlaylists(category: category)
            if !radios.isEmpty { cachedArtistRadios[category.rawValue] = radios }
        }
        return (try? JSONEncoder().encode(radios)) ?? Data("[]".utf8)
    }

    /// Every radio currently mirrored to Qobuz, across ALL categories — backs the
    /// client's unified "AI-radio's op Qobuz" view so it no longer depends on the
    /// (far-away) category picker. Client apps fetch the server's set; the server
    /// and analyzer GUI build locally, rebuilding only the categories that actually
    /// have a radio on Qobuz (a stored Qobuz id) and keeping the mirrored ones.
    public func mirroredRadios() async -> [SonicRadioPlaylist] {
        if isRemote, let base = remoteBaseURL {
            return await fetchRadiosFromServer(base: base, categoryParam: "all")
        }
        var out: [SonicRadioPlaylist] = []
        for cat in RadioCategory.allCases {
            let ids = Self.liveRadioIDs(cat)
            guard ids.contains(where: { UserDefaults.standard.string(forKey: Self.qobuzIDKey($0)) != nil })
            else { continue }
            var radios = cachedArtistRadios[cat.rawValue] ?? []
            if radios.isEmpty {
                radios = await buildRadioPlaylists(category: cat)
                if !radios.isEmpty { cachedArtistRadios[cat.rawValue] = radios }
            }
            out.append(contentsOf: radios.filter { $0.qobuzPlaylistID != nil })
        }
        return out
    }

    /// JSON for the share server's `/artist-radios?category=all` endpoint.
    public func mirroredRadiosData() async -> Data {
        (try? JSONEncoder().encode(await mirroredRadios())) ?? Data("[]".utf8)
    }

    // MARK: Remote fetch (client apps)

    /// Fetch the server's current AI radio set for a category (or "all") over HTTP
    /// so client apps always show the same playlists as Qobuz (instead of building
    /// locally).
    private func fetchRadiosFromServer(base: String, categoryParam: String) async -> [SonicRadioPlaylist] {
        guard let url = URL(string: "\(base)/artist-radios?category=\(categoryParam)") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let radios = try? JSONDecoder().decode([SonicRadioPlaylist].self, from: data) else {
            Log.warning("Radio's (\(categoryParam)) ophalen van server mislukt", category: .network)
            return []
        }
        return radios
    }

    // MARK: Daypart rotation
    //
    // To keep the Qobuz mirror small, the server only syncs ARTIST (always) plus
    // ONE category that fits the current part of the day — the others are removed
    // and return when their daypart comes round. The in-app daily radios still
    // build every category locally, so nothing is lost there; only the Qobuz copy
    // rotates. (Morning is deliberately calm — see `daypartRestrictKeys`.)

    enum Daypart: String, Sendable { case ochtend, middag, avond, nacht }

    /// 4 dayparts by local hour: ochtend 06–12, middag 12–18, avond 18–24, nacht 00–06.
    nonisolated static func currentDaypart(hour: Int) -> Daypart {
        switch hour {
        case 6..<12:  return .ochtend
        case 12..<18: return .middag
        case 18..<24: return .avond
        default:      return .nacht
        }
    }

    /// The rotating category mirrored alongside artist for a daypart.
    nonisolated static func daypartCategory(_ d: Daypart) -> RadioCategory {
        switch d {
        case .ochtend: return .activity
        case .middag:  return .genre
        case .avond:   return .mood
        case .nacht:   return .decade
        }
    }

    /// Optional bucket-key whitelist for the rotating category. Only the morning is
    /// shaped: a calm set of activities (no workout/energiek). Other dayparts use
    /// the category's default (largest / chronological) buckets.
    nonisolated static func daypartRestrictKeys(_ d: Daypart) -> [String]? {
        switch d {
        case .ochtend: return ["focus", "lounge", "chillen"]
        default:       return nil
        }
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
                if !self.radioSyncEnabled {
                    Log.info("AI radio auto-sync staat uit (Instellingen → Radio's).", category: .network)
                } else if !self.qobuzConfigured {
                    Log.warning("AI radio auto-sync overgeslagen — Qobuz is niet ingesteld op de server (Instellingen → Server).", category: .network)
                } else if let selection = self.radioSyncSelection {
                    // Explicit per-radio selection: mirror exactly those radios; no
                    // daypart rotation. An empty selection clears our Qobuz mirror.
                    if selection.isEmpty {
                        if let email = KeychainStore.load(key: "qobuz_email"), !email.isEmpty,
                           let pw = KeychainStore.load(key: "qobuz_password"), !pw.isEmpty {
                            await self.reconcileQobuzRadios(keepIDs: [], email: email, password: pw)
                        }
                        Log.info("AI radio auto-sync: geen radio's geselecteerd — Qobuz-mirror leeggemaakt.", category: .network)
                        didSync = true
                    } else {
                        let total = await self.syncSelectedRadiosToQobuz(selection)
                        didSync = total > 0
                        Log.info("AI radio auto-sync (selectie): \(total)/\(selection.count) geselecteerde radio('s) naar Qobuz", category: .network)
                    }
                } else {
                    // Legacy default (no selection saved yet): daypart rotation —
                    // ARTIST + the current daypart's category. Sync both without a
                    // per-call reconcile, then ONE scoped reconcile prunes the rest.
                    let hour = Calendar.current.component(.hour, from: Date())
                    let daypart = Self.currentDaypart(hour: hour)
                    let rotating = Self.daypartCategory(daypart)
                    let restrict = Self.daypartRestrictKeys(daypart)

                    var total = await self.syncRadiosToQobuz(category: .artist, reconcile: false)
                    total += await self.syncRadiosToQobuz(category: rotating, restrictKeys: restrict, reconcile: false)

                    if let email = KeychainStore.load(key: "qobuz_email"), !email.isEmpty,
                       let pw = KeychainStore.load(key: "qobuz_password"), !pw.isEmpty {
                        await self.reconcileQobuzRadios(keepCategories: [.artist, rotating], email: email, password: pw)
                    }
                    didSync = total > 0
                    Log.info("AI radio auto-sync (\(daypart.rawValue)): \(total) playlist(s) — artiest + \(rotating.rawValue) — naar Qobuz", category: .network)
                }
                // Re-sync on the full cadence once it's working; retry sooner while
                // still warming up (library/features not ready yet, or no Qobuz).
                let wait = didSync ? Self.artistRadioRefreshInterval : 15 * 60 * 1_000_000_000
                try? await Task.sleep(nanoseconds: wait)
            }
        }
        Log.info("AI radio auto-sync gestart (eerste poging na 20s, daarna elke 3 uur; artiest + dagdeel-categorie)", category: .roon)
    }

    public func stopArtistRadioRefresh() {
        artistRadioRefreshTask?.cancel()
        artistRadioRefreshTask = nil
    }
}
