import AVFoundation
import Foundation

public struct TrackMetadata: Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var year: Int?
    public var genre: String?
}

/// Reads embedded tags (Vorbis comments / ID3 / iTunes) via AVFoundation.
public struct MetadataReader {

    /// Broken tags produce years like 4018 or 0; a bad year is worse than none
    /// (a 4018 tag once minted a ghost "decade:4010" radio on Qobuz). Accept
    /// only plausible values.
    static func saneYear(_ v: String?) -> Int? {
        guard let v, let y = Int(v.prefix(4)), (1900...2035).contains(y) else { return nil }
        return y
    }

    public static func read(url: URL) -> TrackMetadata {
        let asset = AVURLAsset(url: url)
        var m = TrackMetadata()

        func apply(_ items: [AVMetadataItem]) {
            for item in items {
                let value = item.stringValue
                if let key = item.commonKey {
                    switch key {
                    case .commonKeyTitle:       m.title  = m.title  ?? value
                    case .commonKeyArtist,
                         .commonKeyAuthor:      m.artist = m.artist ?? value
                    case .commonKeyAlbumName:   m.album  = m.album  ?? value
                    case .commonKeyType:        m.genre  = m.genre  ?? value
                    case .commonKeyCreationDate:
                        if let y = saneYear(value) { m.year = m.year ?? y }
                    default: break
                    }
                }
                // Vorbis/ID3 raw keys (FLAC etc. surface here, not commonMetadata).
                if let raw = (item.key as? String)?.uppercased() ?? item.identifier?.rawValue.uppercased() {
                    if raw.contains("ARTIST"), m.artist == nil { m.artist = value }
                    else if raw.contains("ALBUM"), m.album == nil { m.album = value }
                    else if raw.contains("TITLE"), m.title == nil { m.title = value }
                    else if raw.contains("GENRE"), m.genre == nil { m.genre = value }
                    else if (raw.contains("DATE") || raw.contains("YEAR")), m.year == nil,
                            let y = saneYear(value) { m.year = y }
                }
            }
        }

        apply(asset.commonMetadata)
        for format in asset.availableMetadataFormats {
            apply(asset.metadata(forFormat: format))
        }
        return m
    }
}
