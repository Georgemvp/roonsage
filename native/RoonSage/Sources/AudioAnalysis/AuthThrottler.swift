import Foundation

/// Anti-brute-force throttle for the token-gated HTTP servers (LMS-style).
/// Lives in AudioAnalysis because it's the one library both servers
/// (RoonSageCore's LibraryShareServer on 5767, AnalyzerCore's HTTPServer on
/// 5766) already depend on.
///
/// Semantics: after `maxFailures` *consecutive* auth failures from one client
/// IP, that IP is refused for `penalty` seconds after its latest failure. A
/// successful auth clears the counter. The table is capped: when full, the
/// stalest entry is evicted (an attacker rotating IPs can't grow memory).
public final class AuthThrottler: @unchecked Sendable {
    private struct Entry {
        var failures: Int
        var lastFailure: Date
    }

    private let maxFailures: Int
    private let penalty: TimeInterval
    private let maxEntries: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init(maxFailures: Int = 5, penalty: TimeInterval = 3, maxEntries: Int = 1000) {
        self.maxFailures = max(1, maxFailures)
        self.penalty = penalty
        self.maxEntries = max(1, maxEntries)
    }

    /// True when this IP must be refused right now (respond 429 without even
    /// comparing tokens — that's the point: no oracle, no timing).
    public func isThrottled(_ ip: String, now: Date = Date()) -> Bool {
        guard !ip.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[ip], e.failures >= maxFailures else { return false }
        if now.timeIntervalSince(e.lastFailure) < penalty { return true }
        return false
    }

    public func recordFailure(_ ip: String, now: Date = Date()) {
        guard !ip.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if entries[ip] == nil, entries.count >= maxEntries,
           let stalest = entries.min(by: { $0.value.lastFailure < $1.value.lastFailure })?.key {
            entries.removeValue(forKey: stalest)
        }
        var e = entries[ip] ?? Entry(failures: 0, lastFailure: now)
        e.failures += 1
        e.lastFailure = now
        entries[ip] = e
    }

    public func recordSuccess(_ ip: String) {
        guard !ip.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: ip)
    }
}
