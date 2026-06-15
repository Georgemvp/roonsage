import Foundation
import Network

/// Minimal HTTP server the client apps talk to. Exposes the synced library (so
/// the iPhone can import it instead of an hours-long Browse walk), the synced
/// settings, and — for the playback proxy — live playback state plus a command
/// endpoint so client apps control Roon through this server (only this process
/// registers a Roon extension).
///   GET  /library  → exportLibraryJSON()
///   GET  /settings → SyncableSettings
///   GET  /playback?zone=… → PlaybackSnapshot (live zones/now-playing/queue)
///   POST /command  → RemoteCommand (play/pause/volume/curate/…)
///   GET  /health   → {"tracks": n}
public final class LibraryShareServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 5767   // 5766 is the analyzer

    // MARK: - Access token
    //
    // The server exposes the full library AND the synced settings — which carry
    // secrets (API keys, Last.fm session, Qobuz password). Binding on all
    // interfaces with no auth would hand those to anyone on the network. Every
    // endpoint but /health requires a shared secret, sent in `tokenHeader` (kept
    // out of the URL so it never lands in access logs). Same-machine (loopback)
    // callers are exempt; see `route`.

    /// Header a client sends its shared secret in.
    public static let tokenHeader = "X-RoonSage-Token"
    private static let tokenKey = "share_token"
    private static var cachedToken: String?

    /// The server's shared secret — generated once and persisted in the Keychain.
    /// Warmed in `start()` so request handling is a cache hit.
    public static func currentToken() -> String {
        if let c = cachedToken { return c }
        if let t = KeychainStore.load(key: tokenKey), !t.isEmpty { cachedToken = t; return t }
        var bytes = [UInt8](repeating: 0, count: 24)
        for i in bytes.indices { bytes[i] = .random(in: .min ... .max) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        KeychainStore.save(key: tokenKey, value: token)
        cachedToken = token
        return token
    }

    /// Token configured on this device — the server's generated one, or (on a
    /// client) the value the user pasted from the server. nil if unset.
    public static var configuredToken: String? { KeychainStore.load(key: tokenKey) }

    /// Set/clear the token on this device (client pairing UI).
    public static func setConfiguredToken(_ value: String) {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { KeychainStore.delete(key: tokenKey); cachedToken = nil }
        else { KeychainStore.save(key: tokenKey, value: t); cachedToken = t }
    }

    /// When false (default) unauthenticated requests are still served but logged
    /// — a grace window so existing clients keep working until they're paired.
    /// Flip to true to hard-reject them. A *wrong* token is always rejected.
    public static var enforceToken: Bool {
        get { UserDefaults.standard.bool(forKey: "share_token_enforce") }
        set { UserDefaults.standard.set(newValue, forKey: "share_token_enforce") }
    }

    private let port: UInt16
    private let database: DatabaseManager
    private var listener: NWListener?

    public init(port: UInt16 = LibraryShareServer.defaultPort, database: DatabaseManager) {
        self.port = port
        self.database = database
    }

    public func start() throws {
        _ = Self.currentToken()   // warm the token cache before any request
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: .global())
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        let loopback = Self.endpointIsLoopback(conn.endpoint)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.receive(conn, accumulated: Data(), loopback: loopback)
            case .failed, .cancelled: conn.cancel()
            default: break
            }
        }
        conn.start(queue: .global())
    }

    /// Accumulate until the full request (headers + any POST body) has arrived,
    /// then route. POST bodies don't always land in the first read.
    private func receive(_ conn: NWConnection, accumulated: Data, loopback: Bool) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else { conn.cancel(); return }
            var buf = accumulated
            if let data { buf.append(data) }
            guard let headerEnd = Self.rangeOfHeaderEnd(buf) else {
                if isComplete { conn.cancel() } else { self.receive(conn, accumulated: buf, loopback: loopback) }
                return
            }
            let headerData = buf.subdata(in: buf.startIndex..<headerEnd.lowerBound)
            let header = String(data: headerData, encoding: .utf8) ?? ""
            let bodyStart = headerEnd.upperBound
            let contentLength = Self.contentLength(header)
            let bodyReceived = buf.count - (bodyStart - buf.startIndex)
            if bodyReceived < contentLength, !isComplete {
                self.receive(conn, accumulated: buf, loopback: loopback)
                return
            }
            // `contentLength` is clamped to [0, 32 MB] (see `contentLength`), so
            // this range can never invert — a negative/overflowing header value
            // used to trap here and crash the always-on extension process.
            let bodyEnd = min(bodyStart + contentLength, buf.endIndex)
            let body = buf.subdata(in: min(bodyStart, bodyEnd)..<bodyEnd)
            Task {
                let (status, respBody, ctype) = await self.route(header: header, body: body, loopback: loopback)
                self.send(conn, status: status, body: respBody, ctype: ctype)
            }
        }
    }

    private func send(_ conn: NWConnection, status: String, body: Data, ctype: String) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(ctype)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
        })
    }

    private func route(header: String, body: Data, loopback: Bool) async -> (String, Data, String) {
        let requestLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ").map(String.init)
        let method = parts.first ?? "GET"
        let target = parts.count > 1 ? parts[1] : "/"
        let path = target.split(separator: "?").first.map(String.init) ?? target

        // Auth: everything but /health needs the shared token, unless the peer is
        // loopback (same machine — already OS-trusted) or we're in the grace
        // window. A wrong token is always rejected. /settings carries secrets
        // (API keys, Last.fm session, Qobuz password) so it is ALWAYS gated —
        // grace mode never applies to it.
        if !path.hasPrefix("/health"), !loopback {
            let sensitive = path.hasPrefix("/settings")
            let provided = Self.headerValue(Self.tokenHeader, in: header)
            if let provided, !Self.constantTimeEquals(provided, Self.currentToken()) {
                Log.warning("share-server: rejected \(method) \(path) — bad token", category: .network)
                return ("401 Unauthorized", Data("unauthorized".utf8), "text/plain")
            }
            if provided == nil {
                if Self.enforceToken || sensitive {
                    let why = sensitive ? "secrets endpoint requires a token" : "pair this client with the server token"
                    Log.warning("share-server: rejected \(method) \(path) — no token; \(why)", category: .network)
                    return ("401 Unauthorized", Data("unauthorized".utf8), "text/plain")
                }
                Log.warning("share-server: serving \(method) \(path) WITHOUT a token (grace mode) — pair clients, then enable enforcement in Settings", category: .network)
            }
        }

        if method == "POST", path.hasPrefix("/command") {
            let ok = await RoonClient.shared.runRemoteCommandData(body)
            return ok ? ("200 OK", Data("{\"ok\":true}".utf8), "application/json")
                      : ("400 Bad Request", Data("bad command".utf8), "text/plain")
        }
        if path.hasPrefix("/playback") {
            let zone = Self.queryValue("zone", in: target)
            let data = await RoonClient.shared.snapshotData(forZone: zone)
            return ("200 OK", data, "application/json")
        }
        if path.hasPrefix("/library") {
            if let body = try? await database.exportLibraryJSON() {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("export failed".utf8), "text/plain")
        }
        if path.hasPrefix("/settings") {
            if let body = try? JSONEncoder().encode(SyncableSettings.exportCurrent()) {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("export failed".utf8), "text/plain")
        }
        if path.hasPrefix("/health") {
            let n = (try? await database.trackCount()) ?? 0
            return ("200 OK", Data("{\"status\":\"ok\",\"tracks\":\(n)}".utf8), "application/json")
        }
        return ("404 Not Found", Data("not found".utf8), "text/plain")
    }

    // MARK: - Tiny HTTP parse helpers

    private static func rangeOfHeaderEnd(_ data: Data) -> Range<Data.Index>? {
        let marker = Data("\r\n\r\n".utf8)
        return data.range(of: marker)
    }

    static func contentLength(_ header: String) -> Int {
        for line in header.split(separator: "\r\n") {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                let n = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
                // Clamp: a negative or overflowing value would invert the body
                // slice range and trap. 32 MB is far above any real command body.
                return max(0, min(n, 32 * 1024 * 1024))
            }
        }
        return 0
    }

    /// Constant-time string compare — plain `==`/`!=` short-circuits on the first
    /// differing byte, leaking the match length via timing. Used for the token.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        var diff = UInt8(ab.count == bb.count ? 0 : 1)
        for i in 0..<Swift.max(ab.count, bb.count) {
            let x = i < ab.count ? ab[i] : 0
            let y = i < bb.count ? bb[i] : 0
            diff |= (x ^ y)
        }
        return diff == 0
    }

    static func headerValue(_ name: String, in header: String) -> String? {
        let lname = name.lowercased()
        for line in header.split(separator: "\r\n") {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == lname {
                let v = kv[1].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// True when the connecting peer is on this machine (127.0.0.0/8, ::1, the
    /// v4-mapped loopback, or "localhost"). Such callers skip the token check.
    private static func endpointIsLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let addr):
            return addr.rawValue.first == 127
        case .ipv6(let addr):
            let b = [UInt8](addr.rawValue)
            guard b.count == 16 else { return false }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }   // ::1
            if b[10] == 0xff, b[11] == 0xff, b[12] == 127 { return true }        // ::ffff:127.x.x.x
            return false
        case .name(let name, _):
            return name == "localhost"
        @unknown default:
            return false
        }
    }

    private static func queryValue(_ name: String, in target: String) -> String? {
        guard let q = target.split(separator: "?").dropFirst().first else { return nil }
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == name {
                return kv[1].removingPercentEncoding ?? String(kv[1])
            }
        }
        return nil
    }
}
