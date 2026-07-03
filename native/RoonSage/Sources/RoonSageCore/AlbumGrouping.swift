import AudioAnalysis
import Foundation

/// Release grouping + typing without MusicBrainz IDs — LMS's own documented
/// fallback path, built on the edition-normalisation we already ship for
/// track matching (`TrackIdentity.cleanTitle` strips "(2017 Remaster)",
/// "(Deluxe Edition)", …).
///
///  - **Version key**: normalized title + primary artist. Two library albums
///    with the same key are editions of the same release ("Andere versies").
///  - **Type**: a conservative heuristic (title markers for live/compilation,
///    track count for single/EP) that sections an artist's discography the way
///    LMS does with MB primary/secondary types. A real MB release-group
///    enrichment can replace this classifier later without touching the UI.
public enum AlbumGrouping {
    public enum AlbumType: String, CaseIterable, Sendable {
        case album, epSingle, live, compilation

        /// Section header (NL), in display order.
        public var label: String {
            switch self {
            case .album: "Albums"
            case .epSingle: "EP's & singles"
            case .live: "Live"
            case .compilation: "Compilaties"
            }
        }
    }

    /// Editions of the same release share this key.
    public static func versionKey(album: String, artist: String?) -> String {
        let title = TrackIdentity.cleanTitle(album).lowercased()
            .trimmingCharacters(in: .whitespaces)
        let artistKey = TrackIdentity.primaryArtist(artist).lowercased()
        return "\(title)|\(artistKey)"
    }

    static let liveMarkers = ["live", "unplugged", "concert", "in concert", "at wembley", "mtv unplugged"]
    static let compilationMarkers = ["greatest hits", "best of", "the collection", "anthology",
                                     "compilation", "singles collection", "essential", "hits"]

    public static func classify(album: String, trackCount: Int) -> AlbumType {
        let lower = album.lowercased()
        // Word-boundary "live" so "Alive" or "Delivery" never match.
        if compilationMarkers.contains(where: { lower.contains($0) }) { return .compilation }
        if liveMarkers.contains(where: { marker in
            lower.range(of: "\\b\(marker)\\b", options: .regularExpression) != nil
        }) { return .live }
        if trackCount > 0, trackCount <= 5 { return .epSingle }
        return .album
    }
}
