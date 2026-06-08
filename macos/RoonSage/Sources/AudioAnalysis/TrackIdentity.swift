import Foundation

/// Content-based track identity, shared by the analyzer and the app so audio
/// features computed from on-disk files match Roon-sourced library tracks.
///
/// `matchKey` deliberately excludes duration (the app has no track duration),
/// matching on the normalised artist|album|title tuple. Both sides run this
/// same Swift normaliser, so they agree regardless of how Python's stable_id
/// (which adds a duration bucket) would hash.
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

    /// Stable, duration-free match key for joining analyzer ↔ app tracks.
    public static func matchKey(artist: String?, album: String?, title: String?) -> String {
        "\(normalise(artist))\u{1f}\(normalise(album))\u{1f}\(normalise(title))"
    }
}
