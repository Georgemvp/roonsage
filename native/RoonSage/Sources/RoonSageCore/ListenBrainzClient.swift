import Foundation

/// Submits listens to ListenBrainz. Token is stored in Keychain.
public actor ListenBrainzClient {

    public static let shared = ListenBrainzClient()

    private let endpoint = URL(string: "https://api.listenbrainz.org/1/submit-listens")!
    private let apiBase = "https://api.listenbrainz.org"

    /// `listenedAt` is the play START time (Unix seconds). The gated commit
    /// fires minutes into the track, so without it ListenBrainz would record
    /// the submit time instead — drifting every listen by up to the gate
    /// length and disagreeing with the Last.fm scrobble (which uses the start).
    public func submit(title: String, artist: String?, album: String?,
                       listenedAt: Int? = nil, token: String) async {
        guard !token.isEmpty else { return }

        var trackMeta: [String: Any] = ["track_name": title]
        if let a = artist { trackMeta["artist_name"] = a }
        if let al = album { trackMeta["additional_info"] = ["release_name": al] }

        let body: [String: Any] = [
            "listen_type": "single",
            "payload": [[
                "listened_at": listenedAt ?? Int(Date().timeIntervalSince1970),
                "track_metadata": trackMeta
            ]]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Playlists

    /// A reference to a ListenBrainz playlist (metadata only — tracks are fetched
    /// separately via `playlistTracks(mbid:token:)`).
    public struct PlaylistRef: Sendable {
        public let mbid: String
        public let title: String
    }

    /// A single track inside a ListenBrainz playlist.
    public struct PlaylistTrack: Sendable {
        public let title: String
        public let artist: String?
        public let album: String?
    }

    /// Resolve the username that owns `token` via GET /1/validate-token.
    /// Returns nil when the token is empty/invalid.
    public func resolveUsername(token: String) async -> String? {
        guard let data = await get("/1/validate-token", token: token) else { return nil }
        struct Response: Decodable { let valid: Bool?; let user_name: String? }
        guard let r = try? JSONDecoder().decode(Response.self, from: data),
              r.valid == true, let name = r.user_name, !name.isEmpty else { return nil }
        return name
    }

    /// All playlists visible to the user: the ones they created plus (optionally)
    /// the LB-generated "created for you" playlists (Weekly Jams, Daily Jams, …).
    /// De-duplicated by MBID.
    public func userPlaylists(username: String, token: String,
                              includeCreatedFor: Bool = true) async -> [PlaylistRef] {
        let user = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        // LB defaults to 25 per page; ask for the max (100) so we don't silently
        // drop playlists for users with a large collection.
        var refs = await fetchPlaylistList("/1/user/\(user)/playlists?count=100", token: token)
        if includeCreatedFor {
            refs += await fetchPlaylistList("/1/user/\(user)/playlists/createdfor?count=100", token: token)
        }
        var seen = Set<String>()
        return refs.filter { !$0.mbid.isEmpty && seen.insert($0.mbid).inserted }
    }

    /// Fetch the tracks of one playlist via GET /1/playlist/{mbid}. Tracks without
    /// a title are dropped.
    public func playlistTracks(mbid: String, token: String) async -> [PlaylistTrack] {
        let id = mbid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? mbid
        guard let data = await get("/1/playlist/\(id)", token: token) else { return [] }
        guard let resp = try? JSONDecoder().decode(JSPFFull.self, from: data) else { return [] }
        return (resp.playlist.track ?? []).compactMap { t in
            guard let title = t.title, !title.isEmpty else { return nil }
            let artist = t.creator?.isEmpty == false ? t.creator : nil
            let album = t.album?.isEmpty == false ? t.album : nil
            return PlaylistTrack(title: title, artist: artist, album: album)
        }
    }

    // MARK: - Internal

    private func fetchPlaylistList(_ path: String, token: String) async -> [PlaylistRef] {
        guard let data = await get(path, token: token) else { return [] }
        guard let resp = try? JSONDecoder().decode(JSPFList.self, from: data) else { return [] }
        return (resp.playlists ?? []).compactMap { wrapper in
            let mbid = Self.mbid(from: wrapper.playlist.identifier?.value ?? "")
            guard !mbid.isEmpty else { return nil }
            return PlaylistRef(mbid: mbid, title: wrapper.playlist.title ?? "ListenBrainz-playlist")
        }
    }

    private func get(_ path: String, token: String) async -> Data? {
        guard !token.isEmpty, let url = URL(string: apiBase + path) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Extract the playlist MBID from a JSPF identifier URL
    /// (e.g. "https://listenbrainz.org/playlist/<mbid>" → "<mbid>").
    private static func mbid(from identifier: String) -> String {
        identifier.split(separator: "/").last.map(String.init) ?? ""
    }

    // MARK: - JSPF decoding (only the fields we need; `extension` maps are ignored)

    /// JSPF `identifier` is a URI string at the playlist level but an array at the
    /// track level — accept either so decoding never throws on a shape mismatch.
    private struct FlexibleIdentifier: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { value = s }
            else if let a = try? c.decode([String].self) { value = a.first ?? "" }
            else { value = "" }
        }
    }

    private struct JSPFList: Decodable {
        struct Wrapper: Decodable { let playlist: Meta }
        struct Meta: Decodable {
            let title: String?
            let identifier: FlexibleIdentifier?
        }
        let playlists: [Wrapper]?
    }

    private struct JSPFFull: Decodable {
        struct Body: Decodable { let track: [Track]? }
        struct Track: Decodable {
            let title: String?
            let creator: String?
            let album: String?
        }
        let playlist: Body
    }
}
