import Foundation

/// The library-first weekly discovery selection — **"Ontdek Wekelijks"**.
///
/// This reuses the smart-radio ranking core (`RadioEngine` → `RadioSequencer`), but
/// with a different *intent* than a station. A station plays what sounds like its
/// seed; the weekly seeds on the tracks you play **most** and then deliberately
/// **excludes everything you've heard recently**, so the result is music you already
/// own but have been neglecting — a personal Discover Weekly that never leaves your
/// library.
///
/// Pure + deterministic given `salt` (the ISO week stamp): a rebuild inside the same
/// week reproduces the same set unless the library or history changed. Runs off the
/// main actor — the orchestrator (`RoonClient+DiscoverWeekly`) does the DB/LLM/HTTP
/// I/O; everything here is testable without a database.
public enum DiscoverWeekly {

    // MARK: Options

    public struct Options: Sendable {
        /// Final playlist length.
        public var trackCount: Int
        /// 0 = close to your most-played, 1 = far/new. Higher than a normal station's
        /// default so the weekly leans into discovery.
        public var adventurousness: Double
        /// Tracks played within this many days are excluded — that's what makes it
        /// discovery rather than a replay. `0` disables the exclusion.
        public var exclusionDays: Int
        /// Cap per artist so no single artist dominates the week.
        public var maxPerArtist: Int

        public init(trackCount: Int = 30, adventurousness: Double = 0.55,
                    exclusionDays: Int = 30, maxPerArtist: Int = 2) {
            self.trackCount = max(1, trackCount)
            self.adventurousness = min(1, max(0, adventurousness))
            self.exclusionDays = max(0, exclusionDays)
            self.maxPerArtist = max(1, maxPerArtist)
        }
    }

    // MARK: Seeds & exclusion (the testable primitives)

    /// Seeds = tracks you play a lot that are present (and analyzed) in the library.
    /// These anchor the CLAP similarity search — the weekly's "sounds like what you
    /// love". Two things keep it from freezing on the same anchors every week:
    ///   • plays are **log-dampened + recency-weighted** (`SonicDNA.playWeight`), so a
    ///     handful of 1000+-play tracks no longer outweigh everything else ~20×; and
    ///   • given a `salt` (the ISO week), the seeds are **weighted-sampled** from your
    ///     top tracks per week, so a different loved set anchors each week's search.
    /// With no `salt` (or too small a library to rotate) it stays deterministic:
    /// heaviest-weighted first, capped to `limit`.
    public static func selectSeeds(
        playStats: [(matchKey: String, count: Int, lastPlayed: String)],
        byMatchKey: [String: DatabaseManager.SonicTrack],
        limit: Int,
        salt: String = "",
        now: Date = Date()
    ) -> [DatabaseManager.SonicTrack] {
        let limit = max(1, limit)
        // Resolve to analyzed, in-library tracks, each carrying a recency-dampened
        // play weight — log(1+count)·recency, the curve SonicDNA/TasteVector use. The
        // log() is what stops a few 1000+-play tracks from monopolising the seeds.
        let ranked = playStats
            .compactMap { s -> (track: DatabaseManager.SonicTrack, weight: Double)? in
                guard !s.matchKey.isEmpty, let t = byMatchKey[s.matchKey] else { return nil }
                return (t, SonicDNA.playWeight(count: s.count, lastPlayed: s.lastPlayed, now: now))
            }
            .sorted { $0.weight == $1.weight ? $0.track.id < $1.track.id : $0.weight > $1.weight }

        // No week salt (deterministic callers/tests) or too small a pool to rotate →
        // keep the old behaviour: heaviest-first, capped.
        guard !salt.isEmpty, ranked.count > limit else {
            return Array(ranked.prefix(limit).map(\.track))
        }

        // Rotate WITHIN your top tracks: restrict to a widened pool (so seeds stay
        // genuinely well-loved), then weighted-sample `limit` of them WITHOUT
        // replacement (Efraimidis-Spirakis: key = u^(1/w), keep the largest keys),
        // with `u` deterministic per ISO week per track.
        let pool = ranked.prefix(min(ranked.count, max(limit * 4, 120)))
        let keyed = pool.map { item -> (track: DatabaseManager.SonicTrack, key: Double) in
            let u = (Double(RoonClient.seed64("\(salt)\u{1f}\(item.track.id)") % 1_000_000) + 0.5) / 1_000_000
            let w = max(item.weight, 1e-6)
            return (item.track, pow(u, 1.0 / w))
        }
        return Array(keyed.sorted { $0.key > $1.key }.prefix(limit).map(\.track))
    }

    /// Content keys played within `days` before `now` — excluded from the weekly so
    /// it's discovery, not a replay of this week's rotation. `days == 0` (or an
    /// unparseable timestamp) excludes nothing.
    public static func recentlyPlayedKeys(
        playStats: [(matchKey: String, count: Int, lastPlayed: String)],
        withinDays days: Int, now: Date = Date()
    ) -> Set<String> {
        guard days > 0 else { return [] }
        let parser = ISO8601DateFormatter()
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var keys = Set<String>()
        for s in playStats where !s.matchKey.isEmpty {
            guard let d = parser.date(from: s.lastPlayed) else { continue }
            if d >= cutoff { keys.insert(s.matchKey) }
        }
        return keys
    }

    // MARK: Plan

    /// Rank the library around `seeds` (CLAP similarity + taste steering via
    /// `RadioEngine`), drop anything recently played or disliked, cap per-artist, and
    /// flow-order the survivors into a gently rising arc. Returns ordered
    /// `SonicTrack`s (the orchestrator maps them to `TrackRecord` and optionally
    /// appends ListenBrainz enrichment). Empty when there's nothing to rank (no
    /// seeds / no embeddings).
    public static func plan(
        seeds: [DatabaseManager.SonicTrack],
        library: [DatabaseManager.SonicTrack],
        index: VectorIndex,
        recentlyPlayedKeys: Set<String>,
        disliked: Set<String>,
        likedKeys: Set<String>,
        knownArtists: Set<String>,
        tasteVector: [Float]?,
        options: Options,
        salt: String
    ) -> [DatabaseManager.SonicTrack] {
        guard !seeds.isEmpty else { return [] }

        // A wide, UNSEQUENCED ranked pool — big enough that the recency exclusion and
        // the per-artist cap still have plenty to fill `trackCount` from.
        let poolLimit = max(options.trackCount * 12, 300)
        let opts = RadioEngine.Options(
            adventurousness: options.adventurousness, poolLimit: poolLimit,
            hardBanDisliked: false, sequence: false)
        let ranked = RadioEngine.rank(
            seeds: seeds, library: library, index: index, options: opts,
            disliked: disliked, likedKeys: likedKeys, knownArtists: knownArtists,
            tasteVector: tasteVector, salt: salt)

        // Discovery exclusion: drop recently-played + disliked, dedupe by content key.
        // (RadioEngine already excludes the seeds themselves.)
        var seen = Set<String>()
        var kept: [DatabaseManager.SonicTrack] = []
        for t in ranked.map(\.track) {
            if !t.matchKey.isEmpty, recentlyPlayedKeys.contains(t.matchKey) { continue }
            if !t.matchKey.isEmpty, disliked.contains(t.matchKey) { continue }
            let key = t.matchKey.isEmpty ? t.id : t.matchKey
            if seen.insert(key).inserted { kept.append(t) }
        }
        guard !kept.isEmpty else { return [] }

        // Per-artist cap + top-up to trackCount — reuse the artist-radio round-robin
        // (one track per artist before any artist's second, dup-version collapse).
        let byId = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let capped = RoonClient.capForPlaylist(
            kept.map { TrackRecord(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) },
            seedArtist: "", minTracks: options.trackCount, maxTracks: options.trackCount,
            maxPerArtist: options.maxPerArtist)
        let sonic = capped.compactMap { byId[$0.id] }

        // Flow-order into a gentle rise so it plays like a designed set, not a
        // relevance dump.
        return RadioSequencer.order(sonic, arc: .gentleRise)
    }
}
