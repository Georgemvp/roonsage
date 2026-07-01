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

    /// Seeds = the tracks you play most that are present (and analyzed) in the
    /// library, ordered by play count and capped to `limit`. These anchor the CLAP
    /// similarity search — the weekly's "sounds like what you love".
    public static func selectSeeds(
        playStats: [(matchKey: String, count: Int, lastPlayed: String)],
        byMatchKey: [String: DatabaseManager.SonicTrack],
        limit: Int
    ) -> [DatabaseManager.SonicTrack] {
        Array(playStats
            .sorted { $0.count > $1.count }
            .compactMap { byMatchKey[$0.matchKey] }
            .prefix(max(1, limit)))
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
