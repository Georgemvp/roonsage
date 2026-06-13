import Foundation
import GRDB

public struct TrackRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "tracks"

    public var id: String          // Roon item_key
    public var title: String
    public var artist: String?
    public var album: String?
    public var albumKey: String?
    public var year: Int?
    public var isLive: Bool
    public var matchKey: String?
    public var imageKey: String?

    public init(
        id: String,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        albumKey: String? = nil,
        year: Int? = nil,
        isLive: Bool = false,
        matchKey: String? = nil,
        imageKey: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumKey = albumKey
        self.year = year
        self.isLive = isLive
        self.matchKey = matchKey
        self.imageKey = imageKey
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, year
        case albumKey = "album_key"
        case isLive   = "is_live"
        case matchKey = "match_key"
        case imageKey = "image_key"
    }
}
