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
        feedbackGenreRates: [String: (approve: Double, strongNeg: Double)],
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
            resolved.append(item)
        }
        resolved = Self.rededupe(resolved)

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

        // 3c. Resolve artist-kind items to a representative Qobuz cover — they
        // have no specific album to play, so the feed would otherwise show a
        // placeholder icon for every artist recommendation (the large majority
        // of a typical batch).
        if let creds = qobuzCreds {
            let artistWants = resolved.enumerated().compactMap { idx, it -> (key: String, artist: String)? in
                guard it.kind == .artist, it.imageURL == nil else { return nil }
                return (key: String(idx), artist: it.artist)
            }
            if !artistWants.isEmpty {
                let covers = await QobuzClient.shared.resolveArtistCovers(artistWants, email: creds.email, password: creds.password)
                for (keyStr, url) in covers {
                    guard let idx = Int(keyStr), resolved.indices.contains(idx) else { continue }
                    resolved[idx].imageURL = url.absoluteString
                }
            }
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
            comps.popularity = 0
            let base = DiscoveryScoring.weightedScore(weights, comps)

            let finalScore: Double
            if it.kind == .album {
                let recency = DiscoveryScoring.recency(releaseDate: it.releaseDate, now: now)
                finalScore = DiscoveryScoring.applyAlbumModifier(
                    base: base, recency: recency, popularity: nil, gapPriority: it.gapPriority)
                comps.albumModifier = finalScore - base
            } else {
                finalScore = base
            }

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
