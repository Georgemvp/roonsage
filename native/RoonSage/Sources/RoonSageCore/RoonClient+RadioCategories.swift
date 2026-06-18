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
        case artist, genre, mood, activity, decade
        public var id: String { rawValue }
        var idPrefix: String { "\(rawValue):" }

        /// Dutch label for the segmented picker.
        public var label: String {
            switch self {
            case .artist:   return "Artiest"
            case .genre:    return "Genre"
            case .mood:     return "Sfeer"
            case .activity: return "Activiteit"
            case .decade:   return "Decennium"
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
        let disliked = dislikedMatchKeys

        let genres = category == .genre ? ((try? await db.genresByTrackID()) ?? [:]) : [:]
        let years  = category == .decade ? ((try? await db.yearByMatchKey()) ?? [:]) : [:]

        return await Task.detached {
            Self.buildBuckets(category: category, lib: lib, genres: genres, years: years,
                              disliked: disliked, daySeed: stamp)
        }.value
    }

    // MARK: Pure bucket builder (off-main)

    nonisolated static func buildBuckets(
        category: RadioCategory,
        lib: [DatabaseManager.SonicTrack],
        genres: [String: Set<String>],
        years: [String: Int],
        disliked: Set<String>,
        daySeed: String
    ) -> [RadioBucket] {
        switch category {
        case .artist:   return []
        case .genre:    return genreBuckets(lib: lib, genres: genres, disliked: disliked, daySeed: daySeed)
        case .mood:     return moodBuckets(lib: lib, disliked: disliked, daySeed: daySeed)
        case .activity: return activityBuckets(lib: lib, disliked: disliked, daySeed: daySeed)
        case .decade:   return decadeBuckets(lib: lib, years: years, disliked: disliked, daySeed: daySeed)
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

    /// Dutch labels for the analyzer's mood dimensions; falls back to a capitalised
    /// key for any mood we don't have a translation for.
    private nonisolated static func moodLabel(_ key: String) -> String {
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
    private struct ActivityProfile {
        let key: String
        let label: String
        let matches: (DatabaseManager.SonicTrack) -> Bool
        /// Higher = better seed for this activity (drives seed ordering).
        let rank: (DatabaseManager.SonicTrack) -> Double
    }

    private nonisolated static var activityProfiles: [ActivityProfile] {
        func e(_ t: DatabaseManager.SonicTrack) -> Double { t.energy ?? 0.5 }
        func b(_ t: DatabaseManager.SonicTrack) -> Double { t.bpm ?? 0 }
        return [
            ActivityProfile(key: "workout", label: "Workout",
                            matches: { e($0) >= 0.7 && b($0) >= 120 },
                            rank: { e($0) + b($0) / 200 }),
            ActivityProfile(key: "onderweg", label: "Onderweg",
                            matches: { e($0) >= 0.5 && e($0) <= 0.85 && b($0) >= 95 && b($0) <= 140 },
                            rank: { e($0) }),
            ActivityProfile(key: "chillen", label: "Chillen",
                            matches: { e($0) < 0.4 && b($0) < 110 },
                            rank: { 1 - e($0) }),
            ActivityProfile(key: "lounge", label: "Lounge",
                            matches: { e($0) >= 0.4 && e($0) <= 0.6 && b($0) < 115 },
                            rank: { 1 - e($0) }),
            ActivityProfile(key: "energiek", label: "Energiek",
                            matches: { e($0) >= 0.72 },
                            rank: { e($0) }),
            ActivityProfile(key: "focus", label: "Focus",
                            matches: { e($0) >= 0.25 && e($0) <= 0.55 && b($0) >= 70 && b($0) <= 120 },
                            rank: { 1 - abs(e($0) - 0.4) }),
        ]
    }

    private nonisolated static func activityBuckets(
        lib: [DatabaseManager.SonicTrack], disliked: Set<String>, daySeed: String
    ) -> [RadioBucket] {
        // Keep the curated order (Workout → Focus); skip profiles that don't fill.
        activityProfiles.compactMap { profile in
            let matching = lib.filter(profile.matches).sorted { profile.rank($0) > profile.rank($1) }
            return makeBucket(id: "activity:\(profile.key)", label: profile.label,
                              tracks: matching, disliked: disliked, daySeed: daySeed)
        }
    }

    // MARK: Decade

    private nonisolated static func decadeLabel(_ decade: Int) -> String {
        decade >= 2000 ? "Jaren \(decade)" : "Jaren \(decade % 100)"
    }

    private nonisolated static func decadeBuckets(
        lib: [DatabaseManager.SonicTrack], years: [String: Int],
        disliked: Set<String>, daySeed: String
    ) -> [RadioBucket] {
        guard !years.isEmpty else { return [] }
        var byDecade: [Int: [DatabaseManager.SonicTrack]] = [:]
        for t in lib {
            guard let y = years[t.matchKey], y >= 1900 else { continue }
            byDecade[(y / 10) * 10, default: []].append(t)
        }
        // Newest decade first.
        return byDecade.keys.sorted(by: >).compactMap { decade in
            makeBucket(id: "decade:\(decade)", label: decadeLabel(decade),
                       tracks: byDecade[decade] ?? [], disliked: disliked, daySeed: daySeed)
        }
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
