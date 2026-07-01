import Foundation

// MARK: - Mood-seeded discovery (F12a — "iets als X maar donkerder")
//
// Biases a discovery run toward a mood by reusing the SAME per-track CLAP mood
// scores that already power the mood-radio buckets (RoonClient+RadioCategories) —
// no new ML/embedding infra. Crucially, this only needs mood scores on OWNED,
// analyzed tracks: a not-yet-owned candidate has no embedding to score, so mood
// can't bias the pipeline's Score stage directly. Instead it biases WHERE the
// producers start looking — the artists whose owned tracks best fit the mood
// become the seed every producer already consumes (similar-artist, gap-fill,
// relationships, …), plus the AI producer reads the mood directly (ProducerContext).

public enum MoodSeeding {

    /// One track's mood-relevant facts, decoupled from `DatabaseManager.SonicTrack`
    /// so this stays pure/testable without a DB dependency.
    public struct TrackMoodFacts: Sendable {
        public var artist: String?
        public var moods: [String: Float]   // raw CLAP label (lowercased) → cosine
        public init(artist: String?, moods: [String: Float]) {
            self.artist = artist; self.moods = moods
        }
    }

    /// Artists ranked by mean score for `mood` across their owned, scored tracks —
    /// highest affinity first. Requires at least `minTracks` scored tracks per
    /// artist so a single outlier track can't crown an artist on its own. Matching
    /// is case-insensitive; artists are returned in their first-seen display case.
    /// Empty when the mood has no library presence (caller should fall back).
    public static func topArtists(_ tracks: [TrackMoodFacts], mood: String,
                                  limit: Int, minTracks: Int = 2) -> [String] {
        guard limit > 0 else { return [] }
        let key = mood.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return [] }

        var sums: [String: (total: Float, count: Int, display: String)] = [:]
        for t in tracks {
            // Case-insensitive on both sides: real data is lowercase (the CLAP
            // label set), but don't assume it — a linear scan over ~6 mood entries
            // is cheap.
            guard let raw = t.artist?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
                  let score = t.moods.first(where: { $0.key.lowercased() == key })?.value else { continue }
            let k = raw.lowercased()
            var entry = sums[k] ?? (0, 0, raw)
            entry.total += score; entry.count += 1
            sums[k] = entry
        }
        return sums.values
            .filter { $0.count >= minTracks }
            .sorted { lhs, rhs in
                let l = lhs.total / Float(lhs.count), r = rhs.total / Float(rhs.count)
                return l != r ? l > r : lhs.display < rhs.display   // stable tie-break
            }
            .prefix(limit)
            .map(\.display)
    }
}
