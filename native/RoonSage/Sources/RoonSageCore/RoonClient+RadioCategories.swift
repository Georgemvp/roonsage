import Foundation

// MARK: - Radio categories
//
// Sonic radios aren't only seeded by ARTIST anymore. A radio is fully defined by
// its `seedIds` (the tracks whose CLAP centroid the station grows around) plus a
// display label and a stable `id` prefix — so the same playback + Qobuz machinery
// works for any way of bucketing the analyzed library:
//
//   • artist   — the artists you play most            (id "artist:<key>")
//   • genre    — discriminating genres/tags           (id "genre:<key>")
//   • mood     — the analyzer's mood dimensions        (id "mood:<key>")
//   • activity — curated energy/tempo profiles         (id "activity:<key>")
//   • decade   — release decade (from file-tag years)  (id "decade:<yyyy>")
//
// Artist buckets keep their existing (play-history scored / stable-seed) logic;
// the other four are built here by `radioBuckets(_:)`. Categories or individual
// buckets without enough analyzed tracks are silently skipped.

extension RoonClient {

    /// One way to slice the library into radios. `artist` is the legacy default.
    public enum RadioCategory: String, CaseIterable, Sendable, Identifiable {
        case artist, genre, mood, activity, decade, sonic
        public var id: String { rawValue }
        var idPrefix: String { "\(rawValue):" }

        /// Recover the category from a stable radio id ("genre:house" → .genre),
        /// so a mixed radio set can be grouped back by category in the UI.
        public init?(radioID: String) {
            guard let prefix = radioID.split(separator: ":", maxSplits: 1).first.map(String.init),
                  let c = RadioCategory(rawValue: prefix) else { return nil }
            self = c
        }

        /// Dutch label for the segmented picker.
        public var label: String {
            switch self {
            case .artist:   return "Artiest"
            case .genre:    return "Genre"
            case .mood:     return "Sfeer"
            case .activity: return "Activiteit"
            case .decade:   return "Decennium"
            case .sonic:    return "Buurten"
            }
        }
    }

    /// A library slice ready to become a radio (daily station or Qobuz playlist).
    struct RadioBucket: Sendable {
        let id: String          // "<category>:<key>"
        let label: String       // display name (carried in SonicRadio.artist)
        let imageKey: String?   // artwork from a representative seed
        let seedIds: [String]   // centroid seeds (capped, daily-shuffled)
        let trackCount: Int     // full bucket size (for the card subtitle)
    }

    /// Minimum analyzed tracks for a non-artist bucket to qualify (higher than the
    /// artist floor so genre/mood/decade stations are substantial, not one-offs).
    nonisolated static let categoryRadioMinTracks = 8
    /// Cap on non-artist buckets surfaced per category (keeps the grid + Qobuz set
    /// from exploding when the library has dozens of genres/decades).
    nonisolated static let categoryRadioMax = 8

    // MARK: Bucket building (gathers on main, computes off-main)

    /// Build the radio buckets for a non-artist category. Returns `[]` for
    /// `.artist` (artist radios keep their own seed logic in Radio/ArtistRadio).
    func radioBuckets(_ category: RadioCategory) async -> [RadioBucket] {
        guard category != .artist, let db = database else { return [] }
        let lib = await radioLibrary()
        guard !lib.isEmpty else { return [] }
        let stamp = Self.dayStamp()
        let disliked = radioDislikedMatchKeys

        // Sonic neighborhoods are discovered by clustering the CLAP embeddings, so
        // they need the index (cached). Each cluster becomes a station via the same
        // makeBucket machinery as the metadata categories.
        if category == .sonic {
            guard useSonicEmbeddings else { return [] }
            let clusters = await sonicCache.clusters(from: db)
            guard !clusters.isEmpty else { return [] }
            let byId = Dictionary(lib.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return await Task.detached {
                clusters.prefix(RoonClient.categoryRadioMax).compactMap { cl -> RadioBucket? in
                    let tracks = cl.memberIds.compactMap { byId[$0] }
                    return RoonClient.makeBucket(id: "sonic:\(cl.id)", label: cl.label,
                                                 tracks: tracks, disliked: disliked, daySeed: stamp)
                }
            }.value
        }

        let genres = category == .genre ? ((try? await db.genresByTrackID()) ?? [:]) : [:]
        let years  = category == .decade ? ((try? await db.yearByMatchKey()) ?? [:]) : [:]
        // Activity buckets need the library energy calibration (percentile-based).
        let calibration = category == .activity
            ? await Task.detached { TitleGrounding.Calibration.compute(library: lib) }.value : nil

        return await Task.detached {
            Self.buildBuckets(category: category, lib: lib, genres: genres, years: years,
                              disliked: disliked, daySeed: stamp, calibration: calibration)
        }.value
    }

    // MARK: Pure bucket builder (off-main)

    nonisolated static func buildBuckets(
        category: RadioCategory,
        lib: [DatabaseManager.SonicTrack],
        genres: [String: Set<String>],
        years: [String: Int],
        disliked: Set<String>,
        daySeed: String,
        calibration: TitleGrounding.Calibration? = nil
    ) -> [RadioBucket] {
        switch category {
        case .artist:   return []
        case .genre:    return genreBuckets(lib: lib, genres: genres, disliked: disliked, daySeed: daySeed)
        case .mood:     return moodBuckets(lib: lib, disliked: disliked, daySeed: daySeed)
        case .activity: return activityBuckets(lib: lib, disliked: disliked, daySeed: daySeed, calibration: calibration)
        case .decade:   return decadeBuckets(lib: lib, years: years, disliked: disliked, daySeed: daySeed)
        case .sonic:    return []   // needs the embedding index — built in radioBuckets(_:)
        }
    }

    /// Pack a list of bucket tracks into a `RadioBucket` (seeds = a daily-shuffled,
    /// dislike-free subset; the centroid of that subset defines the station sound,
    /// so it varies a little each day). Returns nil below the qualifying floor.
    private nonisolated static func makeBucket(
        id: String, label: String, tracks: [DatabaseManager.SonicTrack],
        disliked: Set<String>, daySeed: String
    ) -> RadioBucket? {
        let usable = tracks.filter { !disliked.contains($0.matchKey) }
        guard usable.count >= categoryRadioMinTracks else { return nil }
        // Daily-shuffle once; both the seeds AND the cover come from that order, so
        // the artwork is representative of THIS bucket (not the library's first row)
        // and rotates daily — neighbouring buckets no longer share a single cover.
        let shuffled = dailyShuffled(usable, seed: "\(daySeed)|\(id)")
        let seeds = Array(shuffled.prefix(radioMaxSeeds))
        let img = shuffled.first(where: { $0.imageKey?.isEmpty == false })?.imageKey
        return RadioBucket(id: id, label: label, imageKey: img,
                           seedIds: seeds.map(\.id), trackCount: usable.count)
    }

    // MARK: Genre

    private nonisolated static func genreBuckets(
        lib: [DatabaseManager.SonicTrack], genres: [String: Set<String>],
        disliked: Set<String>, daySeed: String
    ) -> [RadioBucket] {
        // Roon's `track_genres` ONLY — the analyzer's free-text `tags`
        // ("peak-time", "warmup", "high-energy", "atmospheric", …) are energy/DJ
        // descriptors, not genres, and would otherwise drown out the real genres.
        // Key on the lowercased form; keep Roon's properly-cased label.
        var byGenre: [String: [DatabaseManager.SonicTrack]] = [:]
        var labelFor: [String: String] = [:]
        for t in lib {
            guard let gs = genres[t.id] else { continue }
            for raw in gs {
                let key = raw.lowercased().trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                byGenre[key, default: []].append(t)
                if labelFor[key] == nil { labelFor[key] = raw }
            }
        }
        let buckets = byGenre.compactMap { (key, tracks) -> RadioBucket? in
            makeBucket(id: "genre:\(key)", label: labelFor[key] ?? key.capitalized,
                       tracks: tracks, disliked: disliked, daySeed: daySeed)
        }
        return Array(buckets.sorted { $0.trackCount > $1.trackCount }.prefix(categoryRadioMax))
    }

    // MARK: Mood

    /// The mood keys the shipped CLAP model actually scores (`clap_mel.json`'s
    /// `mood_labels`) — a small, real subset of the defensive translation table
    /// below, which also covers labels a future model config might add. This is
    /// the list to offer as PICKABLE options (e.g. the Discovery mood-seed menu);
    /// `moodLabel` remains the general-purpose translator for any key.
    public nonisolated static let knownMoodKeys = ["danceable", "aggressive", "happy", "party", "relaxed", "sad"]

    /// Dutch labels for the analyzer's mood dimensions; falls back to a capitalised
    /// key for any mood we don't have a translation for.
    public nonisolated static func moodLabel(_ key: String) -> String {
        let map: [String: String] = [
            "happy": "Vrolijk", "sad": "Melancholisch", "melancholic": "Melancholisch",
            "energetic": "Energiek", "calm": "Kalm", "relaxed": "Ontspannen",
            "aggressive": "Stevig", "dark": "Donker", "romantic": "Romantisch",
            "party": "Feestelijk", "sensual": "Sensueel", "uplifting": "Opwekkend",
            "tender": "Teder", "epic": "Episch", "dreamy": "Dromerig",
            "hopeful": "Hoopvol", "angry": "Woedend", "peaceful": "Vredig",
            "groovy": "Groovy", "dramatic": "Dramatisch", "warm": "Warm",
            "danceable": "Dansbaar",
        ]
        return map[key.lowercased()] ?? key.capitalized
    }

    private nonisolated static func moodBuckets(
        lib: [DatabaseManager.SonicTrack], disliked: Set<String>, daySeed: String
    ) -> [RadioBucket] {
        // Assign each track to its DOMINANT mood (argmax). The analyzer's mood
        // scores rarely cross an absolute 0.5, so a fixed threshold left the buckets
        // nearly empty; argmax gives clean, non-overlapping stations. A small floor
        // skips tracks with no mood that stands out.
        let floor: Float = 0.3
        var byMood: [String: [DatabaseManager.SonicTrack]] = [:]
        for t in lib {
            guard let top = t.moods.max(by: { $0.value < $1.value }), top.value >= floor else { continue }
            byMood[top.key.lowercased(), default: []].append(t)
        }
        let buckets = byMood.compactMap { (key, tracks) -> RadioBucket? in
            makeBucket(id: "mood:\(key)", label: moodLabel(key),
                       tracks: tracks, disliked: disliked, daySeed: daySeed)
        }
        return Array(buckets.sorted { $0.trackCount > $1.trackCount }.prefix(categoryRadioMax))
    }

    // MARK: Activity (curated energy/tempo profiles)

    /// One curated activity profile and the predicate that selects its tracks.
    struct ActivityProfile {
        let key: String
        let label: String
        let matches: @Sendable (DatabaseManager.SonicTrack) -> Bool
        /// Higher = better seed for this activity (drives seed ordering).
        let rank: @Sendable (DatabaseManager.SonicTrack) -> Double
    }

    /// Activity profiles keyed on the LIBRARY-RELATIVE energy percentile (arousal-
    /// or-RMS via `TitleGrounding`), so a compressed absolute energy axis can't
    /// leave "Workout"/"Energiek" permanently empty (the old `energy >= 0.7`
    /// matched zero tracks on a library whose RMS energy maxed at ~0.6). `nil`
    /// calibration falls back to the raw energy signal on a 0…1 assumption.
    nonisolated static func activityProfiles(calibration: TitleGrounding.Calibration?) -> [ActivityProfile] {
        @Sendable func ep(_ t: DatabaseManager.SonicTrack) -> Double {
            calibration?.energyPercentile(t) ?? TitleGrounding.energySignal(t) ?? 0.5
        }
        @Sendable func b(_ t: DatabaseManager.SonicTrack) -> Double { t.bpm ?? 0 }
        // Zero-is-data: a NULL bpm must not slip through a low-tempo `<` gate as 0.
        // The `>=` gates below already exclude nil-as-0 correctly; only the pure
        // upper-bound profiles (chillen/lounge) need an explicit presence guard.
        @Sendable func hasBpm(_ t: DatabaseManager.SonicTrack) -> Bool { t.bpm != nil }
        return [
            ActivityProfile(key: "workout", label: "Workout",
                            matches: { ep($0) >= 0.70 && b($0) >= 120 },
                            rank: { ep($0) + b($0) / 200 }),
            ActivityProfile(key: "onderweg", label: "Onderweg",
                            matches: { ep($0) >= 0.45 && ep($0) <= 0.90 && b($0) >= 95 && b($0) <= 140 },
                            rank: { ep($0) }),
            ActivityProfile(key: "chillen", label: "Chillen",
                            matches: { ep($0) < 0.33 && hasBpm($0) && b($0) < 110 },
                            rank: { 1 - ep($0) }),
            ActivityProfile(key: "lounge", label: "Lounge",
                            matches: { ep($0) >= 0.30 && ep($0) <= 0.60 && hasBpm($0) && b($0) < 115 },
                            rank: { 1 - ep($0) }),
            ActivityProfile(key: "energiek", label: "Energiek",
                            matches: { ep($0) >= 0.72 },
                            rank: { ep($0) }),
            ActivityProfile(key: "focus", label: "Focus",
                            matches: { ep($0) >= 0.20 && ep($0) <= 0.55 && b($0) >= 70 && b($0) <= 120 },
                            rank: { 1 - abs(ep($0) - 0.4) }),
        ]
    }

    private nonisolated static func activityBuckets(
        lib: [DatabaseManager.SonicTrack], disliked: Set<String>, daySeed: String,
        calibration: TitleGrounding.Calibration?
    ) -> [RadioBucket] {
        // Keep the curated order (Workout → Focus); skip profiles that don't fill.
        activityProfiles(calibration: calibration).compactMap { profile in
            let matching = lib.filter(profile.matches).sorted { profile.rank($0) > profile.rank($1) }
            return makeBucket(id: "activity:\(profile.key)", label: profile.label,
                              tracks: matching, disliked: disliked, daySeed: daySeed)
        }
    }

    // MARK: Decade

    private nonisolated static func decadeLabel(_ decade: Int) -> String {
        decade >= 2000 ? "Jaren \(decade)" : "Jaren \(decade % 100)"
    }

    /// Plausible release-year window. Upper bound = next calendar year (pre-
    /// releases). Rejects corrupt tags like "4010" that otherwise spawn a phantom
    /// "Jaren 4010" station.
    nonisolated static func isPlausibleYear(_ y: Int) -> Bool {
        let nextYear = Calendar.current.component(.year, from: Date()) + 1
        return y >= 1900 && y <= nextYear
    }

    private nonisolated static func decadeBuckets(
        lib: [DatabaseManager.SonicTrack], years: [String: Int],
        disliked: Set<String>, daySeed: String
    ) -> [RadioBucket] {
        guard !years.isEmpty else { return [] }
        var byDecade: [Int: [DatabaseManager.SonicTrack]] = [:]
        for t in lib {
            guard let y = years[t.matchKey], isPlausibleYear(y) else { continue }
            byDecade[(y / 10) * 10, default: []].append(t)
        }
        // Newest decade first.
        return byDecade.keys.sorted(by: >).compactMap { decade in
            makeBucket(id: "decade:\(decade)", label: decadeLabel(decade),
                       tracks: byDecade[decade] ?? [], disliked: disliked, daySeed: daySeed)
        }
    }

    // MARK: Measured-feature gates (feature fusion in selection)
    //
    // The k-NN pool around a bucket's seed centroid can drift outside the
    // bucket's DEFINING constraint — a "Workout" station picking up sonically-
    // close ballads, a "Jaren 90" station leaking 2010s tracks. These gates
    // filter the ranked candidates on the *measured* feature that defines the
    // bucket, so the station's name is true by construction. Artist and sonic
    // radios have no gate: there the embedding neighbourhood IS the definition.

    /// The measured-feature gate for a bucket radio id, or nil when the category
    /// doesn't constrain beyond sonic proximity. `genres`/`years` are only read
    /// by the genre/decade gates — pass empty maps otherwise.
    nonisolated static func bucketGate(
        radioID: String,
        genres: [String: Set<String>] = [:],
        years: [String: Int] = [:],
        calibration: TitleGrounding.Calibration? = nil
    ) -> (@Sendable (DatabaseManager.SonicTrack) -> Bool)? {
        guard let sep = radioID.firstIndex(of: ":") else { return nil }
        let cat = String(radioID[..<sep])
        let key = String(radioID[radioID.index(after: sep)...])
        switch cat {
        case "activity":
            guard let p = activityProfiles(calibration: calibration).first(where: { $0.key == key }) else { return nil }
            return p.matches
        case "mood":
            // Same membership rule as the bucket builder: the track's dominant
            // mood — or a clearly-present score on the station's mood.
            return { t in
                if let top = t.moods.max(by: { $0.value < $1.value }), top.key.lowercased() == key { return true }
                return t.moods.first { $0.key.lowercased() == key }.map { $0.value >= 0.3 } ?? false
            }
        case "genre":
            return { t in genres[t.id]?.contains { $0.lowercased() == key } ?? false }
        case "decade":
            guard let decade = Int(key) else { return nil }
            return { t in years[t.matchKey].map { ($0 / 10) * 10 == decade } ?? false }
        default:
            return nil   // artist / sonic / track seeds: proximity is the definition
        }
    }

    /// Isolated convenience: build the gate for `radioID`, fetching the genre/
    /// year maps only when that category actually needs them.
    func candidateGate(for radioID: String) async -> (@Sendable (DatabaseManager.SonicTrack) -> Bool)? {
        guard let db = database else { return nil }
        // User-composed radios: build the combined facet gate from the config so the
        // endless top-up stays true to its definition (genre ∧ mood ∧ activity ∧ …).
        if radioID.hasPrefix("custom:") {
            let id = String(radioID.dropFirst("custom:".count))
            guard let cfg = await radioConfig(id: id) else { return nil }
            let genres = (try? await db.genresByTrackID()) ?? [:]
            let years = cfg.decades.isEmpty ? [:] : ((try? await db.yearByMatchKey()) ?? [:])
            let cal: TitleGrounding.Calibration?
            if cfg.activities.isEmpty {
                cal = nil
            } else {
                let lib = await radioLibrary()
                cal = await Task.detached { TitleGrounding.Calibration.compute(library: lib) }.value
            }
            return Self.customGate(cfg: cfg, genres: genres, years: years, calibration: cal)
        }
        guard let cat = RadioCategory(radioID: radioID) else { return nil }
        switch cat {
        case .artist, .sonic:
            return nil
        case .genre:
            let genres = (try? await db.genresByTrackID()) ?? [:]
            return Self.bucketGate(radioID: radioID, genres: genres)
        case .decade:
            let years = (try? await db.yearByMatchKey()) ?? [:]
            return Self.bucketGate(radioID: radioID, years: years)
        case .mood:
            return Self.bucketGate(radioID: radioID)
        case .activity:
            let lib = await radioLibrary()
            let cal = await Task.detached { TitleGrounding.Calibration.compute(library: lib) }.value
            return Self.bucketGate(radioID: radioID, calibration: cal)
        }
    }

    /// Order-preserving gate with relaxation: matching tracks lead; when they
    /// alone can't fill `minKeep`, the best non-matching candidates top the pool
    /// up (in their ranked order) so a small bucket still yields a full station.
    nonisolated static func gatedWithRelaxation<T>(
        _ ranked: [T], gate: (T) -> Bool, minKeep: Int
    ) -> [T] {
        var matching: [T] = []
        var rest: [T] = []
        for t in ranked { if gate(t) { matching.append(t) } else { rest.append(t) } }
        guard matching.count < minKeep else { return matching }
        return matching + rest.prefix(minKeep - matching.count)
    }

    // MARK: Per-category stable radio ids (Qobuz)
    //
    // Artist radios persist their seeds under the legacy "artistradio.seeds.v1"
    // key (handled in ArtistRadio). The other categories persist the full radio
    // ids they last built, so orphan reconciliation knows the complete keep-set
    // across every category and never deletes another category's live playlists.

    private static func radioIDsKey(_ category: RadioCategory) -> String {
        "artistradio.ids.\(category.rawValue).v1"
    }
    static func loadRadioIDs(_ category: RadioCategory) -> [String] {
        UserDefaults.standard.stringArray(forKey: radioIDsKey(category)) ?? []
    }
    static func saveRadioIDs(_ ids: [String], category: RadioCategory) {
        UserDefaults.standard.set(ids, forKey: radioIDsKey(category))
    }
}
