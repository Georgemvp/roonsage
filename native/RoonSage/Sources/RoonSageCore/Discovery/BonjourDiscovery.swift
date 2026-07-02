import Foundation
import Network

/// Finds RoonSage share servers advertised on the local network via Bonjour
/// (`_roonsage._tcp`, see `LibraryShareServer.bonjourType`). The server always
/// advertises on the LAN, so a browse resolves to its *current* IP — that's how
/// clients keep working after the serving Mac's DHCP address changes, without
/// anyone re-typing an address.
///
/// iOS note: browsing only returns results when the app lists the service type
/// under `NSBonjourServices` in its Info.plist (done in `iosapp/project.yml`).
public enum BonjourDiscovery {
    public static let serviceType = LibraryShareServer.bonjourType

    /// Browse the LAN and return resolved `host:port` pairs for every advertised
    /// RoonSage server. Best-effort and non-throwing: returns whatever resolved
    /// before `timeout`. IPv4 is preferred (LAN servers are reachable there and
    /// it builds clean URLs); link-local IPv6 is skipped.
    public static func discover(timeout: TimeInterval = 3.0) async -> [(host: String, port: UInt16)] {
        let endpoints = await browse(timeout: timeout)
        guard !endpoints.isEmpty else { return [] }
        return await withTaskGroup(of: (host: String, port: UInt16)?.self) { group in
            for ep in endpoints {
                group.addTask { await resolve(ep, timeout: 2.0) }
            }
            var out: [(host: String, port: UInt16)] = []
            var seen = Set<String>()
            for await r in group {
                if let r, seen.insert("\(r.host):\(r.port)").inserted { out.append(r) }
            }
            return out
        }
    }

    // MARK: - Browse

    private static func browse(timeout: TimeInterval) async -> [NWEndpoint] {
        await withCheckedContinuation { (cont: CheckedContinuation<[NWEndpoint], Never>) in
            let box = ContinuationBox(cont)
            let results = ResultsBox()
            let params = NWParameters()
            params.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)
            browser.browseResultsChangedHandler = { found, _ in
                results.set(found.map { $0.endpoint })
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state, box.resumeOnce(results.get()) { browser.cancel() }
            }
            browser.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if box.resumeOnce(results.get()) { browser.cancel() }
            }
        }
    }

    // MARK: - Resolve

    /// Resolve a Bonjour service endpoint to a concrete IP + port by opening a
    /// short-lived connection and reading the negotiated remote endpoint.
    private static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval) async -> (host: String, port: UInt16)? {
        await withCheckedContinuation { (cont: CheckedContinuation<(host: String, port: UInt16)?, Never>) in
            let box = ContinuationBox<(host: String, port: UInt16)?>(cont)
            let conn = NWConnection(to: endpoint, using: .tcp)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint,
                       let h = hostString(host) {
                        if box.resumeOnce((h, port.rawValue)) { conn.cancel() }
                    } else if box.resumeOnce(nil) {
                        conn.cancel()
                    }
                case .failed, .cancelled:
                    if box.resumeOnce(nil) { conn.cancel() }
                default:
                    break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if box.resumeOnce(nil) { conn.cancel() }
            }
        }
    }

    /// Format an `NWEndpoint.Host` for use in an `http://…` URL. Prefers IPv4;
    /// returns nil for link-local IPv6 (needs a scope id, not URL-friendly).
    private static func hostString(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .name(let name, _):
            return name.lowercased() == "localhost" ? nil : name
        case .ipv4(let addr):
            // Network tags addresses with an interface scope ("10.0.0.5%en1");
            // the '%' is illegal in a URL host, so strip it.
            let s = "\(addr)".split(separator: "%").first.map(String.init) ?? "\(addr)"
            // Never hand back loopback: a client that also runs a share server
            // would otherwise "discover" itself and connect to localhost.
            return s.hasPrefix("127.") ? nil : s
        case .ipv6(let addr):
            let s = "\(addr)".split(separator: "%").first.map(String.init) ?? "\(addr)"
            if s.lowercased().hasPrefix("fe80") { return nil }   // link-local
            if s == "::1" { return nil }                         // loopback
            return "[\(s)]"
        @unknown default:
            return nil
        }
    }
}

/// One-shot continuation guard, safe to call from multiple Network callbacks and
/// the timeout without double-resuming.
private final class ContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { cont = c }
    /// Resumes exactly once; returns true only for the winning caller (so it can
    /// own teardown like cancelling the browser/connection).
    func resumeOnce(_ value: T) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let c = cont else { return false }
        cont = nil
        c.resume(returning: value)
        return true
    }
}

/// Thread-safe holder for the browser's latest results (mutated on the Network
/// queue, read from the timeout/finish path).
private final class ResultsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [NWEndpoint] = []
    func set(_ v: [NWEndpoint]) { lock.lock(); value = v; lock.unlock() }
    func get() -> [NWEndpoint] { lock.lock(); defer { lock.unlock() }; return value }
}
