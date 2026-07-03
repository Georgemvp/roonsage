import Foundation

// MARK: - Favorites (starred albums / artists)
//
// LMS-style starring, wired exactly like track feedback: content-derived keys
// (survive resyncs), server-of-record persistence (direct = local DB, remote =
// POST /favorite + GET /favorites), and an in-memory mirror so stars light up
// instantly across views.

/// Wire DTO for POST /favorite. `on: false` unstars.
public struct FavoriteToggle: Codable, Sendable {
    public var kind: String     // "artist" | "album"
    public var key: String
    public var title: String?
    public var artist: String?
    public var on: Bool
    public init(kind: String, key: String, title: String?, artist: String?, on: Bool) {
        self.kind = kind; self.key = key; self.title = title; self.artist = artist; self.on = on
    }
}

public enum FavoriteKind: String, Sendable {
    case artist, album

    /// Content key: stable across resyncs (never a Roon item_key).
    public static func artistKey(_ name: String) -> String { name.lowercased() }
    public static func albumKey(album: String, artist: String?) -> String {
        "\(album.lowercased())|\((artist ?? "").lowercased())"
    }
}

@MainActor
extension RoonClient {
    private static func mirrorKey(_ kind: FavoriteKind, _ key: String) -> String {
        "\(kind.rawValue)\u{1f}\(key)"
    }

    public func isFavoriteArtist(_ name: String) -> Bool {
        favoriteKeys.contains(Self.mirrorKey(.artist, FavoriteKind.artistKey(name)))
    }

    public func isFavoriteAlbum(album: String, artist: String?) -> Bool {
        favoriteKeys.contains(Self.mirrorKey(.album, FavoriteKind.albumKey(album: album, artist: artist)))
    }

    public func toggleFavoriteArtist(_ name: String) async {
        await toggleFavorite(kind: .artist, key: FavoriteKind.artistKey(name), title: name, artist: nil)
    }

    public func toggleFavoriteAlbum(album: String, artist: String?) async {
        await toggleFavorite(kind: .album, key: FavoriteKind.albumKey(album: album, artist: artist),
                             title: album, artist: artist)
    }

    private func toggleFavorite(kind: FavoriteKind, key: String, title: String?, artist: String?) async {
        guard !key.isEmpty else { return }
        let mk = Self.mirrorKey(kind, key)
        let turningOn = !favoriteKeys.contains(mk)
        if turningOn { favoriteKeys.insert(mk) } else { favoriteKeys.remove(mk) }

        if isRemote {
            await postFavorite(FavoriteToggle(kind: kind.rawValue, key: key,
                                              title: title, artist: artist, on: turningOn))
            return
        }
        do {
            if turningOn {
                try await database?.setFavorite(.init(kind: kind.rawValue, key: key,
                                                      title: title, artist: artist))
            } else {
                try await database?.removeFavorite(kind: kind.rawValue, key: key)
            }
        } catch {
            Log.warning("Favoriet opslaan mislukt: \(error)", category: .roon)
            reportError("Favoriet opslaan mislukt — probeer het opnieuw.")
        }
    }

    private func postFavorite(_ fav: FavoriteToggle) async {
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/favorite") else {
            reportError("Geen verbinding met de RoonSage-server.")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(fav)
        authorizeShareRequest(&req)
        req.timeoutInterval = 8
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200 { return }
        reportError("Favoriet opslaan mislukt — is de RoonSage-server bereikbaar?")
    }

    /// Populate the mirror once per session (direct: local DB; remote: /favorites).
    public func ensureFavoritesLoaded() async {
        guard !favoritesLoaded else { return }
        favoritesLoaded = true
        await reloadFavorites()
    }

    public func reloadFavorites() async {
        let entries: [DatabaseManager.FavoriteEntry]
        if isRemote {
            entries = await fetchRemoteFavorites()
        } else {
            entries = (try? await database?.allFavorites()) ?? []
        }
        favoriteKeys = Set(entries.map { "\($0.kind)\u{1f}\($0.key)" })
    }

    private func fetchRemoteFavorites() async -> [DatabaseManager.FavoriteEntry] {
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/favorites") else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 8
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONDecoder().decode([DatabaseManager.FavoriteEntry].self, from: data) else { return [] }
        return entries
    }
}
