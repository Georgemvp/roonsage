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
            case .ready: self?.receive(conn, accumulated: Data())
            case .failed, .cancelled: conn.cancel()
            default: break
            }
        }
        conn.start(queue: .global())
    }

    /// Accumulate until the full request (headers + any POST body) has arrived,
    /// then route. POST bodies don't always land in the first read.
    private func receive(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else { conn.cancel(); return }
            var buf = accumulated
            if let data { buf.append(data) }
            guard let headerEnd = Self.rangeOfHeaderEnd(buf) else {
                if isComplete { conn.cancel() } else { self.receive(conn, accumulated: buf) }
                return
            }
            let headerData = buf.subdata(in: buf.startIndex..<headerEnd.lowerBound)
            let header = String(data: headerData, encoding: .utf8) ?? ""
            let bodyStart = headerEnd.upperBound
            let contentLength = Self.contentLength(header)
            let bodyReceived = buf.count - (bodyStart - buf.startIndex)
            if bodyReceived < contentLength, !isComplete {
                self.receive(conn, accumulated: buf)
                return
            }
            let body = buf.subdata(in: bodyStart..<min(bodyStart + contentLength, buf.endIndex))
            Task {
                let (status, respBody, ctype) = await self.route(header: header, body: body)
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

    private func route(header: String, body: Data) async -> (String, Data, String) {
        let requestLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ").map(String.init)
        let method = parts.first ?? "GET"
        let target = parts.count > 1 ? parts[1] : "/"
        let path = target.split(separator: "?").first.map(String.init) ?? target

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
            if let body = try? database.exportLibraryJSON() {
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
            let n = (try? database.trackCount()) ?? 0
            return ("200 OK", Data("{\"status\":\"ok\",\"tracks\":\(n)}".utf8), "application/json")
        }
        return ("404 Not Found", Data("not found".utf8), "text/plain")
    }

    // MARK: - Tiny HTTP parse helpers

    private static func rangeOfHeaderEnd(_ data: Data) -> Range<Data.Index>? {
        let marker = Data("\r\n\r\n".utf8)
        return data.range(of: marker)
    }

    private static func contentLength(_ header: String) -> Int {
        for line in header.split(separator: "\r\n") {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                return Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
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
