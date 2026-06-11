import Foundation
import Network

/// Minimal HTTP server exposing the synced library so another device (the
/// iPhone) can import it over ZeroTier instead of doing its own hours-long
/// Browse walk. Mirrors AnalyzerCore.HTTPServer (no shared dependency — that
/// target stays app-independent).
///   GET /library → exportLibraryJSON()    GET /health → {"tracks": n}
public final class LibraryShareServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 5767   // 5766 is the analyzer

    private let port: UInt16
    private let database: DatabaseManager
    private var listener: NWListener?

    public init(port: UInt16 = LibraryShareServer.defaultPort, database: DatabaseManager) {
        self.port = port
        self.database = database
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
            header += "Connection: close\r\n\r\n"
            var out = Data(header.utf8); out.append(body)
            conn.send(content: out, completion: .contentProcessed { _ in
                conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            })
        }
    }

    private func route(_ path: String) -> (String, Data, String) {
        if path.hasPrefix("/library") {
            if let body = try? database.exportLibraryJSON() {
                return ("200 OK", body, "application/json")
            }
            return ("500 Internal Server Error", Data("export failed".utf8), "text/plain")
        }
        if path.hasPrefix("/health") {
            let n = (try? database.trackCount()) ?? 0
            return ("200 OK", Data("{\"status\":\"ok\",\"tracks\":\(n)}".utf8), "application/json")
        }
        return ("404 Not Found", Data("not found".utf8), "text/plain")
    }
}
