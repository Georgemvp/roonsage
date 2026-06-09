import Foundation
import Network

/// Minimal HTTP/1.1 server (Network framework, no deps) exposing analyzed
/// features so the app can pull them over ZeroTier.
///   GET /features → JSON array (keyed by match_key)   GET /health → status
public final class HTTPServer {
    private let port: UInt16
    private let store: FeatureStore
    private var listener: NWListener?

    public init(port: UInt16, store: FeatureStore) {
        self.port = port
        self.store = store
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
        if path.hasPrefix("/features") { return ("200 OK", store.exportJSON(), "application/json") }
        if path.hasPrefix("/health") { return ("200 OK", Data("{\"status\":\"ok\",\"tracks\":\(store.count())}".utf8), "application/json") }
        return ("404 Not Found", Data("not found".utf8), "text/plain")
    }
}
