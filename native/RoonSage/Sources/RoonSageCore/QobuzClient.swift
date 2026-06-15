import Foundation
import CryptoKit

/// Minimal Qobuz JSON-API client for saving playlists. Ports the Python
/// qobuz_api flow: log in with one of the known app_ids (no app_secret /
/// request signing needed), search the catalog to resolve our tracks to Qobuz
/// track IDs, then create a playlist and add them.
public actor QobuzClient {

    public static let shared = QobuzClient()

    private let base = "https://www.qobuz.com/api.json/0.2"
    private let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"
    // Known working app_ids from established third-party Qobuz tools.
    private let knownAppIds = ["950096963", "579939560", "942852567"]

    public struct SaveResult: Sendable { public let matched: Int; public let total: Int; public let playlistID: String }

    private struct Session { let appId: String; let token: String }

    public init() {}

    // MARK: - Public entry point

    /// Log in, create a playlist, resolve each (title, artist) to a Qobuz track,
    /// and add the matches. Returns nil only on login/create failure.
    public func savePlaylist(
        name: String,
        tracks: [(title: String, artist: String?)],
        email: String,
        password: String
    ) async -> SaveResult? {
        guard let session = await login(email: email, password: password) else { return nil }
        guard let playlistID = await createPlaylist(name: name, session: session) else { return nil }

        var ids: [Int] = []
        for t in tracks {
            let query = [t.artist, t.title].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if let id = await resolveTrackID(query: query, wantTitle: t.title, wantArtist: t.artist, session: session) {
                ids.append(id)
            }
        }
        if !ids.isEmpty { await addTracks(playlistID: playlistID, trackIDs: ids, session: session) }
        return SaveResult(matched: ids.count, total: tracks.count, playlistID: playlistID)
    }

    /// Verify credentials and return the account display name, or nil.
    public func verify(email: String, password: String) async -> String? {
        guard await login(email: email, password: password) != nil else { return nil }
        return loginDisplay ?? email
    }
    private var loginDisplay: String?

    // MARK: - Login

    private func login(email: String, password: String) async -> Session? {
        let pwMd5 = Insecure.MD5.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
        for appId in knownAppIds {
            for pw in [password, pwMd5] {
                if let s = await tryLogin(email: email, password: pw, appId: appId) { return s }
            }
        }
        return nil
    }

    private func tryLogin(email: String, password: String, appId: String) async -> Session? {
        // app_id is not a secret and stays in the query; the credentials go in
        // the POST body so the email/password never land in a URL query string
        // (which leaks into server access logs and any TLS-terminating proxy).
        var comps = URLComponents(string: "\(base)/user/login")!
        comps.queryItems = [.init(name: "app_id", value: appId)]
        guard let url = comps.url else { return nil }
        var bodyComps = URLComponents()
        bodyComps.queryItems = [
            .init(name: "email", value: email),
            .init(name: "password", value: password),
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyComps.percentEncodedQuery.map { Data($0.utf8) }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["user_auth_token"] as? String, !token.isEmpty else { return nil }
        loginDisplay = (json["user"] as? [String: Any])?["display_name"] as? String
        return Session(appId: appId, token: token)
    }

    // MARK: - API

    private func authedRequest(_ url: URL, session: Session) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue(session.appId, forHTTPHeaderField: "X-App-Id")
        req.setValue(session.token, forHTTPHeaderField: "X-User-Auth-Token")
        return req
    }

    private func resolveTrackID(query: String, wantTitle: String, wantArtist: String?, session: Session) async -> Int? {
        var comps = URLComponents(string: "\(base)/track/search")!
        comps.queryItems = [.init(name: "query", value: query), .init(name: "limit", value: "5")]
        guard let url = comps.url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(for: authedRequest(url, session: session)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (json["tracks"] as? [String: Any])?["items"] as? [[String: Any]],
              !items.isEmpty else { return nil }

        let wt = wantTitle.lowercased()
        let wa = wantArtist?.lowercased()
        func score(_ item: [String: Any]) -> Int {
            var s = 0
            let title = (item["title"] as? String ?? "").lowercased()
            if title == wt { s += 3 } else if title.contains(wt) || wt.contains(title) { s += 1 }
            if let wa, let perf = (item["performer"] as? [String: Any])?["name"] as? String,
               perf.lowercased().contains(wa) || wa.contains(perf.lowercased()) { s += 2 }
            return s
        }
        let best = items.map { ($0, score($0)) }.max { $0.1 < $1.1 }
        guard let (item, s) = best, s >= 1 else { return nil }
        if let id = item["id"] as? Int { return id }
        if let idStr = item["id"] as? String { return Int(idStr) }
        return nil
    }

    private func createPlaylist(name: String, session: Session) async -> String? {
        guard let url = URL(string: "\(base)/playlist/create") else { return nil }
        var req = authedRequest(url, session: session)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["name": name, "description": "Created by RoonSage", "is_public": "false"])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let id = json["id"] as? Int { return String(id) }
        if let id = json["id"] as? String { return id }
        return nil
    }

    private func addTracks(playlistID: String, trackIDs: [Int], session: Session) async {
        guard let url = URL(string: "\(base)/playlist/addTracks") else { return }
        var req = authedRequest(url, session: session)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form([
            "playlist_id": playlistID,
            "track_ids": trackIDs.map(String.init).joined(separator: ","),
        ])
        _ = try? await URLSession.shared.data(for: req)
    }

    private func form(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs: [String] = params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return k + "=" + v
        }
        let body: String = pairs.joined(separator: "&")
        return Data(body.utf8)
    }
}
