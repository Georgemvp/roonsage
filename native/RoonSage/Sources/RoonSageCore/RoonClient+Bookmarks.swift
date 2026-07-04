import Foundation

// MARK: - Bookmarks ("Bewaar voor later")
//
// A lightweight listen-later list across tracks/albums/artists — distinct from
// favorites (love) and feedback (like/dislike). Wired like favorites:
// content-derived keys (survive resyncs), server-of-record persistence
// (direct = local DB, remote = POST /bookmark + GET /bookmarks), and an
// in-memory mirror so the bookmark toggle lights up instantly.

/// Wire DTO for POST /bookmark. `on: false` removes.
public struct BookmarkToggle: Codable, Sendable {
    public var kind: String     // "track" | "album" | "artist"
    public var key: String
    public var title: String?
    public var artist: String?
    public var album: String?
    public var on: Bool
    public init(kind: String, key: String, title: String?, artist: String?, album: String?, on: Bool) {
        self.kind = kind; self.key = key; self.title = title
        self.artist = artist; self.album = album; self.on = on
    }
}

public enum BookmarkKind: String, Sendable, CaseIterable {
    case track, album, artist

    /// Content keys: stable across resyncs (never a Roon item_key).
    public static func trackKey(title: String, artist: String?) -> String {
        "\(title.lowercased())|\((artist ?? "").lowercased())"
    }
    public static func albumKey(album: String, artist: String?) -> String {
        "\(album.lowercased())|\((artist ?? "").lowercased())"
    }
    public static func artistKey(_ name: String) -> String { name.lowercased() }
}

@MainActor
extension RoonClient {
    private static func bmMirrorKey(_ kind: BookmarkKind, _ key: String) -> String {
        "\(kind.rawValue)\u{1f}\(key)"
    }

    // MARK: Query state

    public func isBookmarkedTrack(title: String, artist: String?) -> Bool {
        bookmarkKeys.contains(Self.bmMirrorKey(.track, BookmarkKind.trackKey(title: title, artist: artist)))
    }
    public func isBookmarkedAlbum(album: String, artist: String?) -> Bool {
        bookmarkKeys.contains(Self.bmMirrorKey(.album, BookmarkKind.albumKey(album: album, artist: artist)))
    }
    public func isBookmarkedArtist(_ name: String) -> Bool {
        bookmarkKeys.contains(Self.bmMirrorKey(.artist, BookmarkKind.artistKey(name)))
    }

    // MARK: Toggles

    public func toggleBookmarkTrack(title: String, artist: String?, album: String?) async {
        await toggleBookmark(kind: .track, key: BookmarkKind.trackKey(title: title, artist: artist),
                             title: title, artist: artist, album: album)
    }
    public func toggleBookmarkAlbum(album: String, artist: String?) async {
        await toggleBookmark(kind: .album, key: BookmarkKind.albumKey(album: album, artist: artist),
                             title: album, artist: artist, album: nil)
    }
    public func toggleBookmarkArtist(_ name: String) async {
        await toggleBookmark(kind: .artist, key: BookmarkKind.artistKey(name),
                             title: name, artist: nil, album: nil)
    }

    private func toggleBookmark(kind: BookmarkKind, key: String,
                                title: String?, artist: String?, album: String?) async {
        guard !key.isEmpty else { return }
        let mk = Self.bmMirrorKey(kind, key)
        let turningOn = !bookmarkKeys.contains(mk)
        if turningOn {
            bookmarkKeys.insert(mk)
            bookmarks.insert(.init(kind: kind.rawValue, key: key, title: title,
                                   artist: artist, album: album), at: 0)
        } else {
            bookmarkKeys.remove(mk)
            bookmarks.removeAll { $0.kind == kind.rawValue && $0.key == key }
        }

        if isRemote {
            await postBookmark(BookmarkToggle(kind: kind.rawValue, key: key, title: title,
                                              artist: artist, album: album, on: turningOn))
            return
        }
        do {
            if turningOn {
                try await database?.setBookmark(.init(kind: kind.rawValue, key: key, title: title,
                                                      artist: artist, album: album))
            } else {
                try await database?.removeBookmark(kind: kind.rawValue, key: key)
            }
        } catch {
            Log.warning("Bookmark opslaan mislukt: \(error)", category: .roon)
            reportError("Bewaren mislukt — probeer het opnieuw.")
        }
    }

    private func postBookmark(_ b: BookmarkToggle) async {
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/bookmark") else {
            reportError("Geen verbinding met de RoonSage-server.")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(b)
        authorizeShareRequest(&req)
        req.timeoutInterval = 8
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200 { return }
        reportError("Bewaren mislukt — is de RoonSage-server bereikbaar?")
    }

    // MARK: Load

    /// Populate the mirror once per session (direct: local DB; remote: /bookmarks).
    public func ensureBookmarksLoaded() async {
        guard !bookmarksLoaded else { return }
        bookmarksLoaded = true
        await reloadBookmarks()
    }

    public func reloadBookmarks() async {
        let entries: [DatabaseManager.BookmarkEntry]
        if isRemote {
            entries = await fetchRemoteBookmarks()
        } else {
            entries = (try? await database?.allBookmarks()) ?? []
        }
        bookmarks = entries
        bookmarkKeys = Set(entries.map { "\($0.kind)\u{1f}\($0.key)" })
    }

    private func fetchRemoteBookmarks() async -> [DatabaseManager.BookmarkEntry] {
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/bookmarks") else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 8
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONDecoder().decode([DatabaseManager.BookmarkEntry].self, from: data) else { return [] }
        return entries
    }

    // MARK: Resolve → tracks (play a bookmark later)

    /// Best-effort resolution of a bookmark to playable library tracks:
    ///  - track  → title search, filtered to the bookmarked artist;
    ///  - album  → album search → the album's tracks in order;
    ///  - artist → every album by that artist, flattened (capped).
    public func resolveBookmark(_ b: DatabaseManager.BookmarkEntry) async -> [TrackRecord] {
        switch b.kind {
        case "track":
            let title = b.title ?? ""
            guard !title.isEmpty else { return [] }
            let hits = await searchTracks(query: title)
            let wanted = (b.artist ?? "").lowercased()
            let match = hits.first { wanted.isEmpty || ($0.artist ?? "").lowercased() == wanted } ?? hits.first
            return match.map { [$0] } ?? []
        case "album":
            let name = b.title ?? ""
            guard !name.isEmpty else { return [] }
            let wanted = (b.artist ?? "").lowercased()
            let albums = await searchAlbums(query: name)
            let album = albums.first {
                $0.album.lowercased() == name.lowercased()
                    && (wanted.isEmpty || ($0.artist ?? "").lowercased() == wanted)
            } ?? albums.first
            guard let key = album?.albumKey else { return [] }
            return await tracksForAlbum(key).map(Self.record)
        case "artist":
            let name = b.title ?? ""
            guard !name.isEmpty else { return [] }
            let albums = await albumsByArtist(name).prefix(20)
            var out: [TrackRecord] = []
            for album in albums {
                out += await tracksForAlbum(album.albumKey).map(Self.record)
            }
            return out
        default:
            return []
        }
    }

    private static func record(_ t: DatabaseManager.LibraryTrackRow) -> TrackRecord {
        TrackRecord(id: t.id, title: t.title, artist: t.artist, album: t.album,
                    year: t.year, isLive: t.isLive)
    }
}
