import Foundation

/// Content-based track identity, shared by the analyzer and the app so audio
/// features computed from on-disk files match Roon-sourced library tracks.
///
/// `matchKey` deliberately excludes duration (the app has no track duration)
/// AND album (editions/box-sets diverge between Roon metadata and file tags),
/// matching on a normalised artist|title pair with Roon's track-number prefix
/// and "(feat. …)" credits stripped. Both sides run this same Swift normaliser.
public enum TrackIdentity {

    /// Lowercase, fold diacritics to ASCII, collapse non-alphanumerics to spaces.
    public static func normalise(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US")).lowercased()
        var out = ""
        out.reserveCapacity(folded.count)
        var lastWasSpace = false
        for ch in folded.unicodeScalars {
            if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") {
                out.unicodeScalars.append(ch)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Strip a leading Roon track/disc-number prefix that the album browse
    /// prepends but on-disk file tags don't: "1. ", "13. " and disc-track
    /// "3-10 ", "1-21 ". Only digit-dot or digit-hyphen-digit forms — never a
    /// bare leading number, so "7 Years" / "99 Luftballons" survive.
    static func stripTrackPrefix(_ title: String) -> String {
        title.replacingOccurrences(
            of: #"^\s*(\d+-\d+|\d+\.)\s*"#, with: "", options: .regularExpression)
    }

    /// Strip "(feat. …)" / "[ft. …]" / "(featuring …)" credits, which Roon hides
    /// but file tags keep. Deliberately keeps version parens like (Live)/(Remix)/
    /// (Radio Edit) — those are DIFFERENT recordings and must not be merged.
    static func stripFeat(_ title: String) -> String {
        title.replacingOccurrences(
            of: #"\s*[\(\[]\s*(feat|ft|featuring)\.?\s[^)\]]*[\)\]]"#,
            with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// Stable, duration-free match key for joining analyzer ↔ app tracks.
    ///
    /// Matches on **artist|title only**. `album` is accepted for call-site
    /// compatibility but intentionally ignored (editions/box-sets diverge). The
    /// title is stripped of Roon's track-number prefix and any "(feat. …)"
    /// credit so both sides agree. (Classical/compilation tracks still won't
    /// match — Roon's composer/performer metadata diverges from file tags.)
    public static func matchKey(artist: String?, album: String?, title: String?) -> String {
        let cleaned = stripFeat(stripTrackPrefix(title ?? ""))
        return "\(normalise(artist))\u{1f}\(normalise(cleaned))"
    }
}
