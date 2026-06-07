import Darwin
import Foundation
import RoonProtocol

/// Discovers Roon Cores via the SOOD protocol — UDP multicast to
/// 239.255.90.90:9003 with a broadcast fallback, matching pyroon's strategy.
///
/// Requires macOS "Local Network" permission (NSLocalNetworkUsageDescription
/// in Info.plist) when running as a sandboxed or hardened-runtime app.
public enum SoodDiscovery {

    public struct Core: Sendable, Equatable {
        public let host: String
        public let httpPort: UInt16
        public let uniqueID: String
        public let name: String?
    }

    // MARK: - Public API

    /// Sends a SOOD query and returns all responding Roon Cores.
    /// Filters to `coreID` if provided. Waits up to `timeout` seconds.
    public static func discover(coreID: String? = nil, timeout: TimeInterval = 5) async -> [Core] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let results = sync(coreID: coreID, timeout: timeout)
                continuation.resume(returning: results)
            }
        }
    }

    // MARK: - Sync (runs on a background thread)

    private static func sync(coreID: String?, timeout: TimeInterval) -> [Core] {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return [] }
        defer { Darwin.close(sock) }

        var broadcastOn: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastOn,
                   socklen_t(MemoryLayout<Int32>.size))

        var ttl: UInt8 = 32
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL, &ttl,
                   socklen_t(MemoryLayout<UInt8>.size))

        let query = SOODMessage.makeQuery()
        send(sock: sock, data: query, host: RoonProtocolConstants.soodMulticastIP,
             port: RoonProtocolConstants.soodPort)
        send(sock: sock, data: query, host: "255.255.255.255",
             port: RoonProtocolConstants.soodPort)

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var results: [Core] = []
        var seen = Set<String>()

        while true {
            var buf = [UInt8](repeating: 0, count: 1024)
            var sender = sockaddr_in()
            var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(sock, &buf, buf.count, 0, $0, &senderLen)
                }
            }
            guard n > 0 else { break }

            let data = Data(bytes: buf, count: n)
            guard let msg = try? SOODMessage(parsing: data),
                  msg.type == .response,
                  let portStr = msg.properties["http_port"],
                  let port = UInt16(portStr),
                  let uid = msg.properties["unique_id"]
            else { continue }

            if let filter = coreID, filter != uid { continue }
            guard seen.insert(uid).inserted else { continue }

            let ip = withUnsafePointer(to: sender.sin_addr) {
                String(cString: inet_ntoa($0.pointee))
            }
            results.append(Core(host: ip, httpPort: port, uniqueID: uid,
                                name: msg.properties["name"]))
        }
        return results
    }

    // MARK: - Helpers

    private static func send(sock: Int32, data: Data, host: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        inet_aton(host, &addr.sin_addr)

        data.withUnsafeBytes { bytes in
            withUnsafePointer(to: addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                    _ = Darwin.sendto(sock, bytes.baseAddress, data.count, 0,
                                      addrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
