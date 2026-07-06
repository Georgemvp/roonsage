import AudioAnalysis
import Foundation

// MARK: - Discovery pipeline (orchestrator)
//
// Runs the digarr-style stages: Discover (producers) → merge by identity →
// Resolve (MusicBrainz validate/dedup + Qobuz album match) → Score (weighted
// composite + album modifier) → Filter (in-library / listened / blocked /
// cooldown / threshold) → return the scored, ordered set for the caller to Store.
// Pure of DB/UI: the caller (RoonClient+Discovery) assembles the inputs and
// persists the output.

/// A candidate as it flows through the pipeline, accumulating resolution + score.
struct WorkItem {
    var kind: RecommendationKind
    var artist: String
    var album: String?
    var year: Int?
    var genres: [String]
    var sources: [SourceRef]
    var artistMbid: String?
    var releaseGroupMbid: String?
    var qobuzAlbumID: String?
    var imageURL: String?
    var releaseDate: String?
    var gapPriority: Double?     // set by gap-fill; feeds the album modifier
    var popularity: Double?      // C2: 0…1 from Last.fm listeners (nil = no signal)

    var distinctSources: Int { Set(sources.map { $0.producer }).count }

    var meanSimilarity: Double {
        let vals = sources.map { $0.similarity ?? 0.5 }
        guard !vals.isEmpty else { return 0.5 }
        return vals.reduce(0, +) / Double(vals.count)
    }

    var meanAIConfidence: Double {
        let vals = sources.compactMap { $0.aiConfidence }
        guard !vals.isEmpty else { return 0.5 }
        return vals.reduce(0, +) / Double(vals.count)
    }
}

struct DiscoveryPipeline {
    var producers: [DiscoveryProducer]
    var weights: ScoringWeights = .default
    /// Cap on candidates carried into MB resolution (bounds the 1.1s/req budget).
    var preResolveCap = 90

    func run(
        seeds: DiscoverySeeds,
        context: ProducerContext,
        qobuzCreds: (email: String, password: String)?,
        libraryGenres: Set<String>,
        genreVocabulary: Set<String> = [],
        feedbackGenreRates: [String: (approve: Double, strongNeg: Double)],
        producerReliability: [String: Double] = [:],
        adventurousness: Double = 0.35,
        filterContext: DiscoveryFilterContext,
        maxItems: Int,
        now: Date
    ) async -> [DatabaseManager.StoredRecommendation] {

        // 1. Discover — run every enabled producer concurrently.
        await context.musicBrainz.resetCache()
        let enabled = producers.filter { $0.isEnabled(context) }
        var raw: [Candidate] = []
        await withTaskGroup(of: [Candidate].self) { group in
            for p in enabled {
                group.addTask { await p.discover(seeds: seeds, context: context) }
            }
            for await c in group { raw.append(contentsOf: c) }
        }
        guard !raw.isEmpty else { return [] }

        // 2. Merge by pre-resolution identity so cross-producer agreement becomes
        //    the consensus signal, then keep the strongest `preResolveCap`.
        var merged = Self.merge(raw)
        merged.sort { lhs, rhs in
            if lhs.distinctSources != rhs.distinctSources { return lhs.distinctSources > rhs.distinctSources }
            return lhs.meanSimilarity > rhs.meanSimilarity
        }
        merged = Array(merged.prefix(preResolveCap))

        // 3a. Resolve artists against MusicBrainz — drops names MB can't find
        //     (kills LLM hallucinations) and canonicalises for a second dedup.
        var resolved: [WorkItem] = []
        for var item in merged {
            guard let match = await context.musicBrainz.resolveArtist(name: item.artist) else { continue }
            item.artist = match.name
            item.artistMbid = match.mbid
            // Attach the artist's genres from MB's search tags (free — no extra
            // request) when the producers left the candidate genre-less, which is
            // almost always: the web/LB/AI producers emit bare artist/album names.
            // Without this, genreOverlap + feedbackBoost scoring get empty inputs
            // (dead no-ops) and the "Ontdek-inzichten" genre trend reads 0. Filter
            // the noisy folksonomy tags ("british", "1980s", "seen live") down to
            // real genres via the MB taxonomy; keep the top handful by vote count.
            // When the taxonomy isn't synced yet the vocabulary is empty — fall back
            // to the raw tags so the feature still populates rather than staying blank.
            if item.genres.isEmpty, !match.tags.isEmpty {
                item.genres = Self.genresFromTags(match.tags, vocabulary: genreVocabulary)
            }
            resolved.append(item)
        }
        resolved = Self.rededupe(resolved)

        // 3a-ter. (PERF-M5) Drop identity-rejected candidates (in-library /
        // already-listened / permanently blocked / within reject cooldown) NOW —
        // right after MB canonicalisation gives us stable artist names — instead of
        // only after the album/cover resolution below. None of these rules depend on
        // the release-group MBID (3a-bis), the Qobuz album id (3b), or cover art
        // (3b-bis/3c), so resolving all of that for a candidate that's guaranteed to
        // be filtered just burns MB/Qobuz round-trips and wall-clock. Seeds are drawn
        // from top/liked/watchlisted artists, so a meaningful fraction of resolved
        // candidates ARE already-owned by construction (gap-fill's whole job is
        // proposing albums by owned artists). Correctness is unchanged: the final
        // Score/Filter step re-applies the full rule set with the fully-resolved
        // dedup key, so a cooldown/block that only becomes keyable once 3a-bis sets
        // the release-group MBID is still caught there — this early pass can only
        // drop a strict subset (identity signals that don't need later resolution).
        resolved = resolved.filter { it in
            let dedup = DiscoveryKey.dedupKey(kind: it.kind, artist: it.artist, album: it.album,
                                              artistMbid: it.artistMbid, releaseGroupMbid: it.releaseGroupMbid)
            // A score that can never trip the (score-dependent) threshold rule, so
            // only the identity-based rejections (1-4) can fire here.
            return DiscoveryFilter.keep(kind: it.kind, artist: it.artist, album: it.album,
                                        dedupKey: dedup, score: .greatestFiniteMagnitude, context: filterContext)
        }
        guard !resolved.isEmpty else { return [] }

        // 3a-bis. Validate `.album` candidates that carry no release-group MBID —
        // i.e. ai-picks, where an LLM names album titles freely and can hallucinate
        // a plausible title for a real artist (gap-fill / release-radar always set a
        // MBID from MB's own discography, so they skip this). Match the title against
        // the artist's real MB studio discography; on a hit, attach the MBID —
        // upgrading it to a verified album that also earns a real Cover Art Archive
        // cover in 3b-bis. Titles matching neither here nor on Qobuz (3b) are dropped
        // in 3b-drop as likely hallucinations.
        for idx in resolved.indices {
            guard resolved[idx].kind == .album, resolved[idx].releaseGroupMbid == nil,
                  let mbid = resolved[idx].artistMbid, !mbid.isEmpty,
                  let title = resolved[idx].album else { continue }
            let disco = await context.musicBrainz.studioAlbums(artistMbid: mbid)
            let wantTitle = TrackIdentity.normalise(title)
            guard !wantTitle.isEmpty,
                  let hit = disco.first(where: { TrackIdentity.normalise($0.title) == wantTitle })
            else { continue }
            resolved[idx].releaseGroupMbid = hit.mbid
            if resolved[idx].year == nil { resolved[idx].year = hit.year }
        }

        // 3b. Resolve album-kind items to a playable Qobuz album (one login).
        if let creds = qobuzCreds {
            let wants = resolved.enumerated().compactMap { idx, it -> (key: String, artist: String, album: String)? in
                guard it.kind == .album, let alb = it.album, it.qobuzAlbumID == nil else { return nil }
                return (key: String(idx), artist: it.artist, album: alb)
            }
            if !wants.isEmpty {
                let hits = await QobuzClient.shared.resolveAlbums(wants, email: creds.email, password: creds.password)
                for (keyStr, album) in hits {
                    guard let idx = Int(keyStr), resolved.indices.contains(idx) else { continue }
                    resolved[idx].qobuzAlbumID = album.id
                    resolved[idx].imageURL = album.coverURL?.absoluteString ?? resolved[idx].imageURL
                    resolved[idx].releaseDate = album.releaseDate ?? resolved[idx].releaseDate
                    if resolved[idx].year == nil, let d = album.releaseDate, let y = Int(d.prefix(4)) {
                        resolved[idx].year = y
                    }
                }
            }
        }

        // 3b-drop. Remove `.album` candidates that resolved on NEITHER Qobuz (3b)
        // NOR MusicBrainz (3a-bis) — an unverifiable album title, i.e. a likely
        // ai-picks hallucination (real artist + invented album). gap-fill /
        // release-radar albums always carry an MB release-group MBID, so they're
        // never dropped; `.artist`-kind items are untouched. This is what stops a
        // non-existent album from reaching the feed with a "Niet op Qobuz gevonden"
        // flag instead of being suppressed.
        resolved.removeAll { it in
            it.kind == .album
                && (it.qobuzAlbumID?.isEmpty ?? true)
                && (it.releaseGroupMbid?.isEmpty ?? true)
        }

        // 3b-bis. For `.album` items that didn't match on Qobuz but DO carry a
        // MusicBrainz release-group MBID (gap-fill / release-radar candidates are
        // MB-sourced), fetch the REAL cover from the Cover Art Archive. This is the
        // actual album's art — unlike 3c's artist-cover stand-in, which for an
        // album shows a *different* release by the same artist and reads as wrong
        // art (a "moon" cover on a Coldplay album that isn't that album). Only fills
        // art, not playability; the qobuzAlbumID stays nil.
        for idx in resolved.indices {
            guard resolved[idx].kind == .album, resolved[idx].imageURL == nil,
                  let rg = resolved[idx].releaseGroupMbid, !rg.isEmpty else { continue }
            if let url = await context.musicBrainz.coverArt(releaseGroupMbid: rg) {
                resolved[idx].imageURL = url.absoluteString
            }
        }

        // 3c. Backfill a representative Qobuz cover for `.artist`-kind items still
        // missing art (they never had a specific album to resolve, so the artist's
        // own cover is an honest stand-in). NOT applied to `.album`-kind items: for
        // an album, a different-release cover of the same artist is misleading, so
        // an album that resolved on neither Qobuz (3b) nor Cover Art Archive (3b-bis)
        // falls through to the placeholder icon instead.
        if let creds = qobuzCreds {
            let coverWants = resolved.enumerated().compactMap { idx, it -> (key: String, artist: String)? in
                guard it.kind == .artist, it.imageURL == nil else { return nil }
                return (key: String(idx), artist: it.artist)
            }
            if !coverWants.isEmpty {
                let covers = await QobuzClient.shared.resolveArtistCovers(coverWants, email: creds.email, password: creds.password)
                for (keyStr, url) in covers {
                    guard let idx = Int(keyStr), resolved.indices.contains(idx) else { continue }
                    resolved[idx].imageURL = url.absoluteString
                }
            }
        }

        // 3e. C2: attach a popularity signal from Last.fm listeners, when
        // configured, now scoped to candidates that can actually survive filtering.
        // Bounded + graceful — no Last.fm (or a failed call) leaves `popularity`
        // nil, so scoring behaves exactly as before this feature.
        if let creds = context.lastfm {
            resolved = await attachPopularity(resolved, apiKey: creds.apiKey)
        }

        // 4. Score → 5. Filter → order → cap.
        var scored: [(item: WorkItem, score: Double, comps: ScoreComponents, dedup: String)] = []
        for it in resolved {
            var comps = ScoreComponents()
            comps.consensus = DiscoveryScoring.consensus(distinctSources: it.distinctSources)
            comps.similarity = it.meanSimilarity
            comps.genreOverlap = DiscoveryScoring.genreOverlap(candidateGenres: it.genres, libraryGenres: libraryGenres)
            comps.aiConfidence = it.meanAIConfidence
            comps.feedbackBoost = DiscoveryScoring.feedbackBoost(candidateGenres: it.genres, rates: feedbackGenreRates)
            comps.popularity = it.popularity ?? 0   // stored for transparency (weight is 0 in the composite)
            let base = DiscoveryScoring.weightedScore(weights, comps)

            var finalScore: Double
            if it.kind == .album {
                let recency = DiscoveryScoring.recency(releaseDate: it.releaseDate, now: now)
                finalScore = DiscoveryScoring.applyAlbumModifier(
                    base: base, recency: recency, popularity: nil, gapPriority: it.gapPriority)
                comps.albumModifier = finalScore - base
            } else {
                finalScore = base
            }

            // C2 (dial-aware popularity) + C3 (per-producer reliability): bounded
            // post-adjustments that only re-rank within the base composite's ballpark.
            let popNudge = DiscoveryScoring.popularityNudge(popularity: it.popularity, adventurousness: adventurousness)
            let relNudge = DiscoveryScoring.producerReliabilityNudge(
                producers: it.sources.map { $0.producer }, reliabilities: producerReliability)
            finalScore = min(max(finalScore + popNudge + relNudge, 0), 1)

            let dedup = DiscoveryKey.dedupKey(kind: it.kind, artist: it.artist, album: it.album,
                                              artistMbid: it.artistMbid, releaseGroupMbid: it.releaseGroupMbid)
            guard DiscoveryFilter.keep(kind: it.kind, artist: it.artist, album: it.album,
                                       dedupKey: dedup, score: finalScore, context: filterContext) else { continue }
            scored.append((it, finalScore, comps, dedup))
        }
        scored.sort { $0.score > $1.score }

        return scored.prefix(maxItems).map { entry in
            DatabaseManager.StoredRecommendation(
                kind: entry.item.kind, artist: entry.item.artist, artistMbid: entry.item.artistMbid,
                album: entry.item.album, releaseGroupMbid: entry.item.releaseGroupMbid, year: entry.item.year,
                qobuzAlbumID: entry.item.qobuzAlbumID, imageURL: entry.item.imageURL, score: entry.score,
                components: entry.comps, sources: entry.item.sources, genres: entry.item.genres, dedupKey: entry.dedup)
        }
    }

    // MARK: - Popularity (C2)

    /// Cap on how many unique artists get a Last.fm listener lookup per run — a
    /// generous ceiling over a normal resolved set, so it's a real bound (logged
    /// when hit) rather than a silent truncation.
    static let popularityFetchCap = 120

    /// Fill each item's `popularity` (0…1) from its artist's Last.fm listener count.
    /// Fetches unique artists with bounded concurrency (polite to Last.fm's rate
    /// limit); any artist that fails to resolve simply keeps `popularity == nil`.
    private func attachPopularity(_ items: [WorkItem], apiKey: String) async -> [WorkItem] {
        var uniqueArtists = [String]()
        var seen = Set<String>()
        for it in items where seen.insert(it.artist.lowercased()).inserted {
            uniqueArtists.append(it.artist)
        }
        if uniqueArtists.count > Self.popularityFetchCap {
            Log.info("Ontdekkingen: popularity-lookup begrensd tot \(Self.popularityFetchCap) van \(uniqueArtists.count) artiesten", category: .roon)
            uniqueArtists = Array(uniqueArtists.prefix(Self.popularityFetchCap))
        }
        guard !uniqueArtists.isEmpty else { return items }

        // Bounded concurrency (≤5 in flight) so a large set doesn't hammer Last.fm.
        var byArtist: [String: Double] = [:]
        let maxConcurrent = 5
        await withTaskGroup(of: (String, Int?).self) { group in
            var iterator = uniqueArtists.makeIterator()
            func addNext() {
                guard let a = iterator.next() else { return }
                group.addTask { (a, await LastfmClient.shared.getArtistListeners(artist: a, apiKey: apiKey)) }
            }
            for _ in 0..<min(maxConcurrent, uniqueArtists.count) { addNext() }
            for await (artist, listeners) in group {
                if let pop = DiscoveryScoring.popularity(listeners: listeners) {
                    byArtist[artist.lowercased()] = pop
                }
                addNext()
            }
        }
        guard !byArtist.isEmpty else { return items }
        return items.map { var it = $0; it.popularity = byArtist[it.artist.lowercased()]; return it }
    }

    // MARK: - Merge helpers

    /// Group raw candidates by pre-resolution identity (kind + normalized artist +
    /// normalized album), unioning their sources/genres so a candidate found by
    /// several producers carries one SourceRef per producer.
    static func merge(_ candidates: [Candidate]) -> [WorkItem] {
        var byKey: [String: WorkItem] = [:]
        for c in candidates {
            let key = preKey(kind: c.kind, artist: c.artist, album: c.album)
            let src = SourceRef(producer: c.producer, similarity: c.similarity,
                                aiConfidence: c.aiConfidence, url: c.sourceURL)
            if var item = byKey[key] {
                if !item.sources.contains(where: { $0.producer == c.producer }) { item.sources.append(src) }
                item.genres = Array(Set(item.genres + c.genres))
                item.artistMbid = item.artistMbid ?? c.artistMbid
                item.releaseGroupMbid = item.releaseGroupMbid ?? c.releaseGroupMbid
                item.year = item.year ?? c.year
                item.gapPriority = item.gapPriority ?? c.gapPriority
                byKey[key] = item
            } else {
                byKey[key] = WorkItem(
                    kind: c.kind, artist: c.artist, album: c.album, year: c.year, genres: c.genres,
                    sources: [src], artistMbid: c.artistMbid, releaseGroupMbid: c.releaseGroupMbid,
                    qobuzAlbumID: nil, imageURL: nil, releaseDate: nil, gapPriority: c.gapPriority)
            }
        }
        return Array(byKey.values)
    }

    /// Second dedup after MB canonicalisation, keyed on the resolved MBID/RG so two
    /// producers' different spellings of the same artist collapse into one item.
    static func rededupe(_ items: [WorkItem]) -> [WorkItem] {
        var byKey: [String: WorkItem] = [:]
        for it in items {
            let key = DiscoveryKey.dedupKey(kind: it.kind, artist: it.artist, album: it.album,
                                            artistMbid: it.artistMbid, releaseGroupMbid: it.releaseGroupMbid)
            if var existing = byKey[key] {
                for s in it.sources where !existing.sources.contains(where: { $0.producer == s.producer }) {
                    existing.sources.append(s)
                }
                existing.genres = Array(Set(existing.genres + it.genres))
                existing.gapPriority = existing.gapPriority ?? it.gapPriority
                byKey[key] = existing
            } else {
                byKey[key] = it
            }
        }
        return Array(byKey.values)
    }

    /// Distil an artist's MB folksonomy tags down to real genres: keep only tags
    /// present in the MB genre `vocabulary` (drops "british"/"1980s"/"seen live"),
    /// preserving the vote-ranked order, and cap at 6. When the vocabulary is empty
    /// (taxonomy not synced yet) fall back to the raw tags so genres still populate
    /// rather than staying blank. Pure — unit-tested in DiscoveryPipelineTests.
    static func genresFromTags(_ tags: [String], vocabulary: Set<String>) -> [String] {
        let genres = vocabulary.isEmpty ? tags : tags.filter { vocabulary.contains($0) }
        return Array(genres.prefix(6))
    }

    static func preKey(kind: RecommendationKind, artist: String, album: String?) -> String {
        let a = TrackIdentity.normalise(artist)
        let al = TrackIdentity.normalise(album ?? "")
        return "\(kind.rawValue)|\(a)|\(al)"
    }

    // MARK: - Skip-if-unchanged guard (scheduler cost control)

    /// A stable signature over exactly the seeds that can change producer output
    /// — top-played, liked, disliked artists and the watchlist. Each list is
    /// reduced to a lowercased Set before hashing, so re-ranking within an
    /// unchanged set (e.g. play-count shuffling the top-artists order) does NOT
    /// flip the signature — only an actual membership change does.
    static func tasteSignature(topArtists: [String], liked: [String], disliked: [String], watchlist: [String]) -> String {
        func norm(_ xs: [String]) -> String {
            Set(xs.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }).sorted().joined(separator: ",")
        }
        let parts = [norm(topArtists), norm(liked), norm(disliked), norm(watchlist)]
        return String(RoonClient.seed64(parts.joined(separator: "|")))
    }

    /// Whether a run can be skipped: the taste signature matches the last stored
    /// batch's AND that batch is still fresh enough for this trigger kind. A
    /// scheduled run tolerates a longer window (external sources like charts/
    /// new-releases drift on their own even with unchanged taste, so scheduled
    /// runs still refresh periodically) than a manual "Ververs" tap, which mainly
    /// guards against re-running the full MB/LLM-costed pipeline for impatient
    /// repeat taps that reflect no actual change. A taste change always forces a
    /// run, regardless of how recent the last one was. Pure — no clock/DB reads,
    /// so it's directly unit-testable.
    static func shouldSkipRun(trigger: String, tasteSig: String, lastBatchSig: String?, lastBatchCreatedAt: Date?, now: Date) -> Bool {
        guard let lastBatchSig, lastBatchSig == tasteSig, let lastBatchCreatedAt else { return false }
        let age = now.timeIntervalSince(lastBatchCreatedAt)
        let minInterval: TimeInterval = trigger == "manual" ? 30 * 60 : 6 * 60 * 60
        return age >= 0 && age < minInterval
    }
}
