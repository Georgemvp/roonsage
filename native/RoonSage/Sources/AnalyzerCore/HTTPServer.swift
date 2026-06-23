import AudioAnalysis
import Foundation
import Network

/// Minimal HTTP/1.1 server (Network framework, no deps) exposing analyzed
/// features so the app can pull them over ZeroTier.
///   GET /features → JSON array (keyed by match_key)
///   GET /embeddings → binary RSEB bundle
///   GET /text-embed?q=… → {"embedding":[…]}  (text→vector for search)
///   GET /health → status
///
/// When `token` is set, every endpoint but `/health` requires it in the
/// `X-RoonSage-Token` header (loopback callers are exempt) — this server hands
/// out the full feature/embedding corpus and runs CPU-bound text inference, so
/// over ZeroTier/LAN it must not be open. `token == nil` keeps it open (local
/// dev) but logs a warning at start.
public final class HTTPServer {
    /// Header a client sends its shared secret in (matches LibraryShareServer).
    public static let tokenHeader = "X-RoonSage-Token"

    private let port: UInt16
    private let store: FeatureStore
    private let token: String?
    private let clapLock = NSLock()
    private var _clap: CLAPModel?
    private var clap: CLAPModel? {
        clapLock.lock(); defer { clapLock.unlock() }; return _clap
    }
    private var listener: NWListener?

    // Response cache: building the full /features JSON (or /embeddings blob) for
    // 24-50k tracks allocates 15-100 MB and was redone on EVERY request — stacking
    // on concurrent polls. Cache the built Data, keyed on the corpus signature, so
    // a request only rebuilds when analyses actually changed. The build runs
    // OUTSIDE the lock (it can take seconds) so requests don't serialize on it.
    private let cacheLock = NSLock()
    private var featuresCache: [String: Data] = [:]   // "sig|embed=0/1" → JSON
    private var featuresCacheSig = ""
    private var embeddingsCache: Data?
    private var embeddingsCacheSig = ""

    private func cachedFeatures(includeEmbedding: Bool) -> Data {
        let sig = store.contentSignature()
        let key = "\(sig)|\(includeEmbedding ? 1 : 0)"
        cacheLock.lock()
        if featuresCacheSig == sig, let hit = featuresCache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let data = store.exportJSON(includeEmbedding: includeEmbedding)
        cacheLock.lock()
        if featuresCacheSig != sig { featuresCache.removeAll(); featuresCacheSig = sig }   // corpus changed → drop stale variants
        featuresCache[key] = data
        cacheLock.unlock()
        return data
    }

    private func cachedEmbeddings() -> Data {
        let sig = store.contentSignature()
        cacheLock.lock()
        if embeddingsCacheSig == sig, let hit = embeddingsCache { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let data = store.embeddingsBlob()
        cacheLock.lock()
        embeddingsCache = data; embeddingsCacheSig = sig
        cacheLock.unlock()
        return data
    }

    public init(port: UInt16, store: FeatureStore, clap: CLAPModel? = nil, token: String? = nil) {
        self.port = port
        self.store = store
        self._clap = clap
        self.token = (token?.isEmpty == false) ? token : nil
    }

    /// Attach (or replace) the CLAP model on a running server without rebinding
    /// the port — lets the server come up instantly for /features + /embeddings
    /// and enable /text-embed once the model finishes loading off-main.
    public func attachCLAP(_ model: CLAPModel?) {
        clapLock.lock(); _clap = model; clapLock.unlock()
    }

    public func start() throws {
        if token == nil {
            FileHandle.standardError.write(Data("⚠︎ analyzer HTTP server on \(port) is UNAUTHENTICATED (no token) — anyone on the network can read features/embeddings. Set ROONSAGE_SHARE_TOKEN.\n".utf8))
        }
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
            case .ready: self?.receive(conn, loopback: loopback)
            case .failed, .cancelled: conn.cancel()
            default: break
            }
        }
        conn.start(queue: .global())
    }

    private func receive(_ conn: NWConnection, loopback: Bool) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let (status, body, ctype) = self.route(path, request: req, loopback: loopback)
            var header = "HTTP/1.1 \(status)\r\n"
            header += "Content-Type: \(ctype)\r\n"
            header += "Content-Length: \(body.count)\r\n"
            header += "Access-Control-Allow-Origin: *\r\n"
            header += "Connection: close\r\n\r\n"
            var out = Data(header.utf8); out.append(body)
            conn.send(content: out, completion: .contentProcessed { _ in
                conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            })
        }
    }

    private func route(_ path: String, request: String, loopback: Bool) -> (String, Data, String) {
        // Auth: everything but /health requires the token unless the peer is on
        // this machine. A missing or wrong token is rejected.
        if let token, !path.hasPrefix("/health"), !loopback {
            let provided = Self.headerValue(Self.tokenHeader, in: request)
            if provided == nil || !Self.constantTimeEquals(provided!, token) {
                return ("401 Unauthorized", Data("{\"error\":\"unauthorized\"}".utf8), "application/json")
            }
        }
        if path.hasPrefix("/text-embed") {
            guard let clap, clap.canEmbedText, let q = Self.queryValue("q", in: path), !q.isEmpty,
                  let vec = try? clap.textEmbedding(q) else {
                return ("404 Not Found", Data("{\"error\":\"text embedding unavailable\"}".utf8), "application/json")
            }
            let body = (try? JSONSerialization.data(withJSONObject: ["embedding": vec.map { Double($0) }])) ?? Data("{}".utf8)
            return ("200 OK", body, "application/json")
        }
        if path.hasPrefix("/embeddings") {
            return ("200 OK", cachedEmbeddings(), "application/octet-stream")
        }
        if path.hasPrefix("/features") {
            let withEmbedding = path.contains("embed=1")
            return ("200 OK", cachedFeatures(includeEmbedding: withEmbedding), "application/json")
        }
        if path.hasPrefix("/health") { return ("200 OK", Data("{\"status\":\"ok\",\"tracks\":\(store.count())}".utf8), "application/json") }
        return ("404 Not Found", Data("not found".utf8), "text/plain")
    }

    /// Read a header value (case-insensitive) from the raw request string.
    static func headerValue(_ name: String, in request: String) -> String? {
        let lname = name.lowercased()
        for line in request.split(separator: "\r\n") {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == lname {
                let v = kv[1].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// Constant-time compare — plain `==` leaks match length via timing.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        var diff = UInt8(ab.count == bb.count ? 0 : 1)
        for i in 0..<Swift.max(ab.count, bb.count) {
            diff |= (i < ab.count ? ab[i] : 0) ^ (i < bb.count ? bb[i] : 0)
        }
        return diff == 0
    }

    /// True when the connecting peer is on this machine (loopback) — exempt from
    /// the token check.
    static func endpointIsLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let addr): return addr.rawValue.first == 127
        case .ipv6(let addr):
            let b = [UInt8](addr.rawValue)
            guard b.count == 16 else { return false }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }   // ::1
            if b[10] == 0xff, b[11] == 0xff, b[12] == 127 { return true }        // ::ffff:127.x
            return false
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    /// Extract + percent-decode a query parameter from a request path.
    static func queryValue(_ name: String, in path: String) -> String? {
        guard let q = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.first.map(String.init) == name, kv.count == 2 else { continue }
            return String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        return nil
    }
}
