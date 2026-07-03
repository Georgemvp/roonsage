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

    // MARK: - Radio / discovery (discovery engine)

    public enum RadioMode: String, Sendable { case easy, medium, hard }

    /// A similar artist surfaced by LB Radio, position-decay scored (first ≈ 0.97,
    /// floors at 0.3 by position 24 — LB's radio endpoint gives no numeric score).
    public struct RadioArtist: Sendable { public let name: String; public let mbid: String; public let score: Double }

    /// `GET /1/lb-radio/artist/{mbid}` — ListenBrainz's own similar-artist radio,
    /// independent of Last.fm's graph. Response is keyed by (arbitrary) recording
    /// group; every value is a list of recordings from ONE similar artist, so we
    /// flatten + dedupe by that artist's mbid, excluding the seed itself.
    public func artistRadio(mbid: String, mode: RadioMode = .medium, token: String) async -> [RadioArtist] {
        guard !mbid.isEmpty else { return [] }
        let path = "/1/lb-radio/artist/\(mbid)?mode=\(mode.rawValue)&max_similar_artists=25&max_recordings_per_artist=2&pop_begin=0&pop_end=100"
        guard let data = await get(path, token: token),
              let res = try? JSONDecoder().decode([String: [RadioRecording]].self, from: data) else { return [] }
        var seen = Set<String>()
        var out: [RadioArtist] = []
        var position = 0
        for recordings in res.values {
            for r in recordings {
                guard r.similar_artist_mbid != mbid, seen.insert(r.similar_artist_mbid).inserted else { continue }
                position += 1
                out.append(RadioArtist(name: r.similar_artist_name, mbid: r.similar_artist_mbid,
                                       score: max(0.3, 1 - Double(position) * 0.03)))
            }
        }
        return out
    }

    private struct RadioRecording: Decodable {
        let similar_artist_mbid: String
        let similar_artist_name: String
    }

    public struct SimilarUser: Sendable { public let username: String; public let similarity: Double }

    /// `GET /1/user/{username}/similar-users` — the LB social graph: users whose
    /// listening overlaps yours, most similar first.
    public func similarUsers(username: String, token: String) async -> [SimilarUser] {
        let user = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        guard let data = await get("/1/user/\(user)/similar-users", token: token) else { return [] }
        struct Response: Decodable { struct U: Decodable { let user_name: String; let similarity: Double }; let payload: [U]? }
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return (r.payload ?? []).map { SimilarUser(username: $0.user_name, similarity: $0.similarity) }
            .sorted { $0.similarity > $1.similarity }
    }

    public struct LBTopArtist: Sendable { public let name: String; public let mbid: String?; public let playCount: Int }

    /// `GET /1/stats/user/{username}/artists?range=` — any user's top artists (used
    /// both to seed User Radio and to read a similar user's taste). 404/empty when
    /// LB hasn't computed stats for that user yet.
    public func topArtists(username: String, range: String = "month", token: String) async -> [LBTopArtist] {
        let user = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        guard let data = await get("/1/stats/user/\(user)/artists?range=\(range)", token: token) else { return [] }
        struct Response: Decodable {
            struct A: Decodable { let artist_name: String; let artist_mbid: String?; let listen_count: Int }
            struct Payload: Decodable { let artists: [A]? }
            let payload: Payload?
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return (r.payload?.artists ?? []).map {
            LBTopArtist(name: $0.artist_name, mbid: ($0.artist_mbid?.isEmpty == false) ? $0.artist_mbid : nil, playCount: $0.listen_count)
        }
    }

    // MARK: - Loved tracks (feedback score 1) — for the loves → likes import

    public struct LovedTrack: Sendable {
        public let title: String
        public let artist: String
    }

    /// All tracks the user "loved" on ListenBrainz, with metadata so they can
    /// be matched to library tracks by title + artist (we don't store per-track
    /// MBIDs). Paginated; capped at `maxCount`.
    public func lovedTracks(username: String, token: String, maxCount: Int = 2000) async -> [LovedTrack] {
        struct Meta: Decodable { let track_name: String?; let artist_name: String? }
        struct Item: Decodable { let score: Int?; let track_metadata: Meta? }
        struct Page: Decodable { let feedback: [Item]?; let total_count: Int? }
        var out: [LovedTrack] = []
        var offset = 0
        let pageSize = 100
        while out.count < maxCount {
            guard let data = await get(
                "/1/feedback/user/\(username)/get-feedback?score=1&metadata=true&count=\(pageSize)&offset=\(offset)",
                token: token),
                let page = try? JSONDecoder().decode(Page.self, from: data),
                let items = page.feedback, !items.isEmpty else { break }
            for i in items {
                guard let m = i.track_metadata, let t = m.track_name, let a = m.artist_name,
                      !t.isEmpty, !a.isEmpty else { continue }
                out.append(LovedTrack(title: t, artist: a))
            }
            offset += items.count
            if let total = page.total_count, offset >= total { break }
        }
        return out
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
