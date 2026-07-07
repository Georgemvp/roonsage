import Foundation

/// Pure, shareable plain-text summaries of the "terugblik" data — what a
/// ShareLink hands to Messages / Mastodon / etc. Deterministic and unit-tested;
/// the views only wrap the string in a share sheet. Empty input yields an empty
/// string so a caller can hide the share affordance.
public enum ShareSummary {
    static let signature = "via RoonSage"

    /// "Op deze dag": a few of the tracks played on today's date in past years.
    public static func onThisDay(_ entries: [DatabaseManager.OnThisDayEntry], max: Int = 5) -> String {
        guard !entries.isEmpty else { return "" }
        let lines = entries.prefix(max).map { e -> String in
            "• \(e.title) — \(e.artist ?? "Onbekend") (\(e.year))"
        }
        return "🎵 Op deze dag draaide ik (\(signature)):\n" + lines.joined(separator: "\n")
    }

    /// "Tijdmachine": top artists per year, newest first.
    public static func tasteTimeMachine(_ periods: [DatabaseManager.TastePeriod],
                                        maxYears: Int = 5, artistsPerYear: Int = 3) -> String {
        guard !periods.isEmpty else { return "" }
        let lines = periods.prefix(maxYears).map { p -> String in
            let names = p.topArtists.prefix(artistsPerYear).map { $0.artist }.joined(separator: ", ")
            return "\(p.year): \(names)"
        }
        return "⏳ Mijn muziek-tijdmachine (\(signature)):\n" + lines.joined(separator: "\n")
    }
}
