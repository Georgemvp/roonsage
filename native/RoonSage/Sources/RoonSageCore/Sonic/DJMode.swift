import Foundation

/// A "DJ persona" — a Guest-DJ preset over the smart-radio engine, inspired by
/// Plexamp's Guest DJs (renamed). Each persona is a *thin preset*, not a new
/// engine: it picks an adventurousness setting, an energy `arc`, and an optional
/// seed-derived candidate `gate`. Those three feed the EXISTING
/// `startRadio → buildRadioCandidates → top-up` runtime unchanged.
///
/// The mapping to the Plexamp Guest DJs we studied:
///   • The Purist     ← the default DJ  (nearest, glued to the seed)
///   • The Wanderer   ← "several similar tracks" — a short sonic adventure
///   • The Vibe       ← the mood-keeper (holds the seed's dominant mood)
///   • The Superfan   ← DJ Groupie      (stays on the same artist)
///   • The Timekeeper ← DJ Contempo     (holds the same era/decade)
///   • The Daredevil  ← DJ Stretch      (the boldest, farthest segues)
public enum DJMode: String, CaseIterable, Sendable, Codable {
    case purist
    case wanderer
    case vibe
    case superfan
    case timekeeper
    case daredevil

    /// The default persona for a fresh station / autoplay.
    public static let `default`: DJMode = .wanderer

    /// Auto-persona for Guest-DJ autoplay: pick a persona by the local hour so the
    /// self-driving station fits the time of day — calm and seamless overnight,
    /// exploratory around midday, favourites in the evening. Pure + deterministic
    /// (the caller supplies the hour, so it's testable without a clock).
    public static func forTimeOfDay(hour: Int) -> DJMode {
        switch ((hour % 24) + 24) % 24 {
        case 5..<9:   return .purist     // early morning — gentle, seamless
        case 9..<12:  return .vibe       // late morning — hold a mood
        case 12..<17: return .wanderer   // afternoon — roam a little
        case 17..<22: return .superfan   // evening — lean into favourites
        default:      return .purist     // late night — deep, close flow
        }
    }

    public var title: String {
        switch self {
        case .purist:     return "The Purist"
        case .wanderer:   return "The Wanderer"
        case .vibe:       return "The Vibe"
        case .superfan:   return "The Superfan"
        case .timekeeper: return "The Timekeeper"
        case .daredevil:  return "The Daredevil"
        }
    }

    /// A short English blurb for the persona card.
    public var blurb: String {
        switch self {
        case .purist:     return "Sticks to the closest sonic match — a seamless deep flow."
        case .wanderer:   return "Drifts through nearby sounds — a short sonic adventure."
        case .vibe:       return "Keeps the mood of the track you started from going."
        case .superfan:   return "Stays with the same artist, deep into their catalogue."
        case .timekeeper: return "Holds the era — more from the same decade."
        case .daredevil:  return "Takes the boldest leaps between tracks."
        }
    }

    /// SF Symbol for the persona card.
    public var symbol: String {
        switch self {
        case .purist:     return "scope"
        case .wanderer:   return "figure.walk"
        case .vibe:       return "waveform"
        case .superfan:   return "heart.fill"
        case .timekeeper: return "clock.arrow.circlepath"
        case .daredevil:  return "bolt.fill"
        }
    }

    /// The adventurousness dial preset (0 = familiar/close, 1 = explorative/far).
    /// Overrides the user's global `radioAdventurousness` while the persona runs.
    public var adventurousness: Double {
        switch self {
        case .purist:     return 0.10
        case .superfan:   return 0.15
        case .vibe:       return 0.30
        case .timekeeper: return 0.30
        case .wanderer:   return 0.45
        case .daredevil:  return 0.80
        }
    }

    /// The energy arc used when flow-ordering the station.
    public var arc: RadioSequencer.Arc {
        switch self {
        case .wanderer:  return .gentleRise
        case .daredevil: return .peak
        default:         return .smooth
        }
    }

    /// A candidate gate derived from the *seed* track, or `nil` when the persona
    /// constrains only by sonic proximity (Purist / Wanderer / Daredevil).
    ///
    /// Reuses the same membership rules the bucket radios use (mood: dominant or
    /// ≥0.3; decade: `year/10*10`). `years` maps `matchKey → release year` and is
    /// read only by The Timekeeper — pass an empty map otherwise. Returns `nil`
    /// (i.e. "no constraint") when the seed lacks the data a gate would need, so
    /// the persona still runs on adventurousness/arc alone rather than silently
    /// producing an empty station.
    public func gate(
        seed: DatabaseManager.SonicTrack,
        years: [String: Int] = [:],
        moodCalibration: MoodCalibration? = nil
    ) -> (@Sendable (DatabaseManager.SonicTrack) -> Bool)? {
        switch self {
        case .purist, .wanderer, .daredevil:
            return nil

        case .vibe:
            // The SEED's mood decides the station, so it must be calibrated too
            // — raw argmax picks whatever label CLAP's text prior inflates.
            guard let topMood = moodCalibration?.dominantMood(seed.moods)
                    ?? seed.moods.max(by: { $0.value < $1.value })?.key.lowercased(),
                  !topMood.isEmpty else { return nil }
            return { t in
                MoodCalibration.matches(topMood, in: t.moods, calibration: moodCalibration)
            }

        case .superfan:
            guard let artist = seed.artist?.lowercased(), !artist.isEmpty else { return nil }
            return { t in (t.artist ?? "").lowercased() == artist }

        case .timekeeper:
            guard let year = years[seed.matchKey] else { return nil }
            let decade = (year / 10) * 10
            return { t in years[t.matchKey].map { ($0 / 10) * 10 == decade } ?? false }
        }
    }
}
