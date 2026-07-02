import Foundation

// MARK: - Persistent HTTP response cache (discovery pipeline)
//
// A small disk-backed, TTL'd response cache shared by the discovery clients.
// The daily discovery run re-resolves the SAME stable seed artists (name→MBID,
// collaboration graph, cover art) every single day — data that effectively
// never changes. The clients already de-dupe within a run (`resetCache()`), but
// nothing survived a process restart, so every daily run paid the full
// rate-limited round-trip again. This persists those immutable responses across
// runs, cutting both run time and rate-limit pressure.
//
// Deliberately NOT used for freshness-sensitive calls (studio release-groups
// feed the release-radar, which must see new albums the day they land) — only
// the callers opt in, per key, with an explicit TTL.
public actor DiscoveryHTTPCache {
    public static let shared = DiscoveryHTTPCache()

    private let dir: URL?
    private var storesSincePrune = 0

    /// One raw response body plus the wall-clock time it was fetched. `body` is a
    /// JSON `Data` blob (base64 in the on-disk envelope via `Codable`).
    private struct Envelope: Codable {
        let key: String
        let at: Double
        let body: Data
    }

    public init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let d = base?.appendingPathComponent("roonsage-discovery-cache", isDirectory: true)
        if let d {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        self.dir = d
    }

    /// Return the cached body for `key` if present and younger than `ttl`.
    public func data(forKey key: String, ttl: TimeInterval) -> Data? {
        guard let url = fileURL(forKey: key),
              let raw = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(Envelope.self, from: raw),
              env.key == key else { return nil }
        // Reject a stale entry (and clean it up so it doesn't linger).
        if Date().timeIntervalSince1970 - env.at > ttl {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return env.body
    }

    /// Persist a fresh response body for `key`.
    public func store(_ body: Data, forKey key: String) {
        guard let url = fileURL(forKey: key) else { return }
        let env = Envelope(key: key, at: Date().timeIntervalSince1970, body: body)
        guard let raw = try? JSONEncoder().encode(env) else { return }
        try? raw.write(to: url, options: .atomic)
        storesSincePrune += 1
        if storesSincePrune >= 200 { storesSincePrune = 0; pruneExpired() }
    }

    // MARK: - Storage

    /// Stable filename for a key via FNV-1a-64 (no crypto dependency; the key is
    /// re-verified on read, so a hash collision can only cause a miss, never a
    /// wrong hit).
    private func fileURL(forKey key: String) -> URL? {
        dir?.appendingPathComponent("\(Self.fnv1a(key)).json")
    }

    static func fnv1a(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// Drop entries older than 60 days — a coarse backstop so the cache directory
    /// can't grow unbounded across months of daily runs. (Per-entry TTLs already
    /// govern correctness; this only reclaims disk.)
    private func pruneExpired() {
        guard let dir,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let cutoff = Date().timeIntervalSince1970 - 60 * 24 * 3600
        for f in files {
            guard let raw = try? Data(contentsOf: f),
                  let env = try? JSONDecoder().decode(Envelope.self, from: raw) else { continue }
            if env.at < cutoff { try? FileManager.default.removeItem(at: f) }
        }
    }
}
