import AudioAnalysis
import Foundation
import Network

/// Minimal HTTP/1.1 server (Network framework, no deps) exposing analyzed
/// features so the app can pull them over ZeroTier.
///   GET /features → JSON array (keyed by match_key)
///   GET /embeddings → binary RSEB bundle
///   GET /text-embed?q=… → {"embedding":[…]}  (text→vector for search)
///   GET /health → status
public final class HTTPServer {
    private let port: UInt16
    private let store: FeatureStore
    private let clap: CLAPModel?
    private var listener: NWListener?

    public init(port: UInt16, store: FeatureStore, clap: CLAPModel? = nil) {
        self.port = port
        self.store = store
        self.clap = clap
    }

    public func start() throws {
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
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.receive(conn)
            case .failed, .cancelled: conn.cancel()
            default: break
            }
        }
        conn.start(queue: .global())
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let (status, body, ctype) = self.route(path)
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

    private func route(_ path: String) -> (String, Data, String) {
        if path.hasPrefix("/text-embed") {
            guard let clap, clap.canEmbedText, let q = Self.queryValue("q", in: path), !q.isEmpty,
                  let vec = try? clap.textEmbedding(q) else {
                return ("404 Not Found", Data("{\"error\":\"text embedding unavailable\"}".utf8), "application/json")
            }
            let body = (try? JSONSerialization.data(withJSONObject: ["embedding": vec.map { Double($0) }])) ?? Data("{}".utf8)
            return ("200 OK", body, "application/json")
        }
        if path.hasPrefix("/embeddings") {
            return ("200 OK", store.embeddingsBlob(), "application/octet-stream")
        }
        if path.hasPrefix("/features") {
            let withEmbedding = path.contains("embed=1")
            return ("200 OK", store.exportJSON(includeEmbedding: withEmbedding), "application/json")
        }
        if path.hasPrefix("/health") { return ("200 OK", Data("{\"status\":\"ok\",\"tracks\":\(store.count())}".utf8), "application/json") }
        return ("404 Not Found", Data("not found".utf8), "text/plain")
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
