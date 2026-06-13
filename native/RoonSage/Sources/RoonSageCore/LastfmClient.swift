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
}
