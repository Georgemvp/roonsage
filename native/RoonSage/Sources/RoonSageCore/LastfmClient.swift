import Foundation
import CryptoKit

/// Last.fm API client: signed scrobbling + the desktop auth flow.
///
/// Signing mirrors the reference pyroon backend: api_sig = md5( concat(key+value
/// for all params except "format", sorted by key) + api_secret ).
///
/// Stateless — credentials are passed per call so Settings/Keychain updates take
/// effect immediately (matching `ListenBrainzClient`). api_key/api_secret are the
/// app's Last.fm API credentials; the session key is obtained once via the auth
/// flow and persisted by the caller.
public actor LastfmClient {

    public static let shared = LastfmClient()

    private let baseURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    public struct Credentials: Sendable {
        public let apiKey: String
        public let apiSecret: String
        public var sessionKey: String?
        public init(apiKey: String, apiSecret: String, sessionKey: String? = nil) {
            self.apiKey = apiKey
            self.apiSecret = apiSecret
            self.sessionKey = sessionKey
        }
    }

    // MARK: - Signing

    private func sign(_ params: [String: String], secret: String) -> String {
        let sigStr = params
            .filter { $0.key != "format" }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined() + secret
        let digest = Insecure.MD5.hash(data: Data(sigStr.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func signedParams(method: String, creds: Credentials, extra: [String: String] = [:]) -> [String: String] {
        var params: [String: String] = ["method": method, "api_key": creds.apiKey, "format": "json"]
        for (k, v) in extra { params[k] = v }
        if let sk = creds.sessionKey, !sk.isEmpty { params["sk"] = sk }
        params["api_sig"] = sign(params, secret: creds.apiSecret)
        return params
    }

    // MARK: - Transport

    private func post(_ params: [String: String]) async -> [String: Any]? {
        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode(params).data(using: .utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              ((resp as? HTTPURLResponse)?.statusCode ?? 500) < 500,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if json["error"] != nil { return nil }   // Last.fm returns {"error": N, "message": ...}
        return json
    }

    private func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map {
            let k = $0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.key
            let v = $0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    // MARK: - Auth flow

    /// Step 1: request a temporary token. Caller then opens `authURL(...)`.
    public func getToken(apiKey: String, apiSecret: String) async -> String? {
        let creds = Credentials(apiKey: apiKey, apiSecret: apiSecret)
        let data = await post(signedParams(method: "auth.getToken", creds: creds))
        return data?["token"] as? String
    }

    /// Step 2: the user must open this URL in a browser and click "Allow".
    public nonisolated func authURL(apiKey: String, token: String) -> URL? {
        URL(string: "https://www.last.fm/api/auth/?api_key=\(apiKey)&token=\(token)")
    }

    /// Step 3: exchange the authorised token for a permanent session key.
    public func getSession(apiKey: String, apiSecret: String, token: String) async -> (name: String, key: String)? {
        let creds = Credentials(apiKey: apiKey, apiSecret: apiSecret)
        let data = await post(signedParams(method: "auth.getSession", creds: creds, extra: ["token": token]))
        guard let session = data?["session"] as? [String: Any],
              let key = session["key"] as? String, !key.isEmpty else { return nil }
        return (name: session["name"] as? String ?? "", key: key)
    }

    // MARK: - Scrobbling

    @discardableResult
    public func updateNowPlaying(artist: String, track: String, album: String?, creds: Credentials) async -> Bool {
        guard canScrobble(creds), !artist.isEmpty, !track.isEmpty else { return false }
        var extra = ["artist": artist, "track": track]
        if let album, !album.isEmpty { extra["album"] = album }
        return await post(signedParams(method: "track.updateNowPlaying", creds: creds, extra: extra)) != nil
    }

    @discardableResult
    public func scrobble(artist: String, track: String, album: String?, timestamp: Int, creds: Credentials) async -> Bool {
        guard canScrobble(creds), !artist.isEmpty, !track.isEmpty else { return false }
        var extra = ["artist": artist, "track": track, "timestamp": String(timestamp)]
        if let album, !album.isEmpty { extra["album"] = album }
        return await post(signedParams(method: "track.scrobble", creds: creds, extra: extra)) != nil
    }

    private nonisolated func canScrobble(_ creds: Credentials) -> Bool {
        !creds.apiKey.isEmpty && !creds.apiSecret.isEmpty && !(creds.sessionKey ?? "").isEmpty
    }

    // MARK: - Read transport (GET, geen signing)

    /// Lees-methodes (user.getRecentTracks/getTop*) vereisen alleen een api_key,
    /// geen handtekening of sessie. Daarom een aparte, ongesigneerde GET.
    private func get(_ params: [String: String]) async -> [String: Any]? {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              ((resp as? HTTPURLResponse)?.statusCode ?? 500) < 500,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if json["error"] != nil { return nil }
        return json
    }

    // MARK: - Recent tracks (voor historie-import)

    public struct Scrobble: Sendable {
        public let artist: String
        public let track: String
        public let album: String?
        public let uts: Int          // unix-timestamp van de scrobble
    }

    public struct RecentPage: Sendable {
        public let scrobbles: [Scrobble]
        public let page: Int
        public let totalPages: Int
        public let total: Int        // totaal aantal scrobbles in het bereik
    }

    /// Eén pagina recente scrobbles. `to` begrenst het bereik (unix-seconden),
    /// zodat we alleen de historie vóór de lokale logging hoeven op te halen.
    /// Het "now playing"-item (zonder datum) wordt overgeslagen.
    public func getRecentTracks(user: String, apiKey: String, page: Int,
                                limit: Int = 200, to: Int? = nil, from: Int? = nil) async -> RecentPage? {
        var params = [
            "method": "user.getrecenttracks", "user": user, "api_key": apiKey,
            "format": "json", "limit": String(limit), "page": String(page),
        ]
        if let to { params["to"] = String(to) }
        if let from { params["from"] = String(from) }
        guard let json = await get(params),
              let rt = json["recenttracks"] as? [String: Any] else { return nil }

        let attr = rt["@attr"] as? [String: Any]
        let totalPages = Int(attr?["totalPages"] as? String ?? "") ?? 0
        let total = Int(attr?["total"] as? String ?? "") ?? 0

        // "track" is een array, maar bij precies één resultaat een los object.
        let raw: [[String: Any]]
        if let arr = rt["track"] as? [[String: Any]] { raw = arr }
        else if let one = rt["track"] as? [String: Any] { raw = [one] }
        else { raw = [] }

        let scrobbles: [Scrobble] = raw.compactMap { t in
            guard let dateObj = t["date"] as? [String: Any],
                  let utsStr = dateObj["uts"] as? String, let uts = Int(utsStr) else { return nil }
            let artist = (t["artist"] as? [String: Any])?["#text"] as? String
                ?? (t["artist"] as? String) ?? ""
            let name = t["name"] as? String ?? ""
            guard !artist.isEmpty, !name.isEmpty else { return nil }
            let albumRaw = (t["album"] as? [String: Any])?["#text"] as? String
            let album = (albumRaw?.isEmpty == false) ? albumRaw : nil
            return Scrobble(artist: artist, track: name, album: album, uts: uts)
        }
        return RecentPage(scrobbles: scrobbles, page: page, totalPages: totalPages, total: total)
    }

    // MARK: - Top artists / tracks / albums (live panels)

    public enum Period: String, Sendable, CaseIterable {
        case week = "7day", month = "1month", quarter = "3month",
             half = "6month", year = "12month", overall

        public var label: String {
            switch self {
            case .week:    return "Week"
            case .month:   return "Maand"
            case .quarter: return "3 mnd"
            case .half:    return "6 mnd"
            case .year:    return "Jaar"
            case .overall: return "Aller tijden"
            }
        }
    }

    public struct TopItem: Sendable, Identifiable {
        public let name: String
        public let artist: String?     // nil voor artiesten zelf
        public let playcount: Int
        public let imageURL: URL?
        public var id: String { (artist ?? "") + "|" + name }
    }

    public func getTopArtists(user: String, apiKey: String, period: Period, limit: Int = 50) async -> [TopItem] {
        await getTop(method: "user.gettopartists", container: "topartists", list: "artist",
                     user: user, apiKey: apiKey, period: period, limit: limit)
    }

    public func getTopTracks(user: String, apiKey: String, period: Period, limit: Int = 50) async -> [TopItem] {
        await getTop(method: "user.gettoptracks", container: "toptracks", list: "track",
                     user: user, apiKey: apiKey, period: period, limit: limit)
    }

    public func getTopAlbums(user: String, apiKey: String, period: Period, limit: Int = 50) async -> [TopItem] {
        await getTop(method: "user.gettopalbums", container: "topalbums", list: "album",
                     user: user, apiKey: apiKey, period: period, limit: limit)
    }

    private func getTop(method: String, container: String, list: String,
                        user: String, apiKey: String, period: Period, limit: Int) async -> [TopItem] {
        let params = [
            "method": method, "user": user, "api_key": apiKey, "format": "json",
            "period": period.rawValue, "limit": String(limit),
        ]
        guard let json = await get(params),
              let top = json[container] as? [String: Any],
              let arr = top[list] as? [[String: Any]] else { return [] }
        return arr.map(Self.parseTopItem)
    }

    private nonisolated static func parseTopItem(_ d: [String: Any]) -> TopItem {
        let name = d["name"] as? String ?? ""
        let playcount = Int(d["playcount"] as? String ?? "") ?? 0
        let artist = (d["artist"] as? [String: Any])?["name"] as? String   // tracks/albums
        let images = d["image"] as? [[String: Any]] ?? []
        let urlStr = (images.first { ($0["size"] as? String) == "extralarge" }?["#text"] as? String)
            ?? (images.last?["#text"] as? String)
        let imageURL = (urlStr?.isEmpty == false) ? URL(string: urlStr!) : nil
        return TopItem(name: name, artist: artist, playcount: playcount, imageURL: imageURL)
    }

    // MARK: - Similar artists / charts (discovery engine)

    /// A neighbour artist. `match` is Last.fm's 0…1 similarity (nil for charts,
    /// where the producer assigns a rank-based similarity instead).
    public struct RelatedArtist: Sendable {
        public let name: String
        public let mbid: String?
        public let match: Double?
    }

    /// `artist.getSimilar` — sonically/statistically similar artists, best first.
    /// Unsigned GET (only an api_key). Backs the Similar-Artist-Web producer.
    public func getSimilarArtists(artist: String, apiKey: String, limit: Int = 30) async -> [RelatedArtist] {
        let params = [
            "method": "artist.getsimilar", "artist": artist, "api_key": apiKey,
            "format": "json", "limit": String(limit), "autocorrect": "1",
        ]
        guard let json = await get(params),
              let sim = json["similarartists"] as? [String: Any] else { return [] }
        let arr = (sim["artist"] as? [[String: Any]]) ?? []
        return arr.compactMap { d in
            guard let name = d["name"] as? String, !name.isEmpty else { return nil }
            let mbid = (d["mbid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let match = Double(d["match"] as? String ?? "")
            return RelatedArtist(name: name, mbid: mbid, match: match)
        }
    }

    /// `artist.getInfo` → global listener count for an artist (C2 popularity signal
    /// for the discovery engine). Unsigned GET; nil when the artist isn't found or
    /// the field is missing, so the scorer treats popularity as "no signal".
    public func getArtistListeners(artist: String, apiKey: String) async -> Int? {
        let params = [
            "method": "artist.getinfo", "artist": artist, "api_key": apiKey,
            "format": "json", "autocorrect": "1",
        ]
        guard let json = await get(params),
              let info = json["artist"] as? [String: Any],
              let stats = info["stats"] as? [String: Any] else { return nil }
        // Last.fm returns counts as strings.
        if let s = stats["listeners"] as? String, let n = Int(s) { return n }
        if let n = stats["listeners"] as? Int { return n }
        return nil
    }

    /// `geo.getTopArtists` — trending artists for a country (or global). Unsigned
    /// GET. Backs the Charts producer. `country` is the Last.fm country NAME
    /// ("United States"), not an ISO code; empty → global (`chart.getTopArtists`).
    public func getTopArtistsByCountry(country: String, apiKey: String, limit: Int = 50) async -> [RelatedArtist] {
        let trimmed = country.trimmingCharacters(in: .whitespaces)
        var params = ["api_key": apiKey, "format": "json", "limit": String(limit)]
        let container: String
        if trimmed.isEmpty || trimmed.lowercased() == "global" {
            params["method"] = "chart.gettopartists"; container = "artists"
        } else {
            params["method"] = "geo.gettopartists"; params["country"] = trimmed; container = "topartists"
        }
        guard let json = await get(params),
              let top = json[container] as? [String: Any],
              let arr = top["artist"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let name = d["name"] as? String, !name.isEmpty else { return nil }
            let mbid = (d["mbid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return RelatedArtist(name: name, mbid: mbid, match: nil)
        }
    }
}
