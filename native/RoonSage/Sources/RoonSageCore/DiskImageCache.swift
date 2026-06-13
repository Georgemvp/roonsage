import CryptoKit
import Foundation

/// On-disk blob cache for album art, keyed by source URL. The in-memory
/// `NSCache` in the UI layer survives a scroll; this survives an app launch and
/// — more importantly — stops re-hitting the Roon Core's HTTP image server for
/// art we've already fetched. Pure `Data`/filesystem (no image type) so it lives
/// in Core and is unit-testable.
public enum DiskImageCache {

    /// Cache directory under Caches/ (the OS may evict it under disk pressure —
    /// fine, it re-fetches). Overridable in tests.
    nonisolated(unsafe) static var directoryOverride: URL?

    private static let defaultDir: URL? = {
        let fm = FileManager.default
        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let d = base.appendingPathComponent("RoonSageArtCache", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func directory() -> URL? {
        if let directoryOverride {
            try? FileManager.default.createDirectory(at: directoryOverride, withIntermediateDirectories: true)
            return directoryOverride
        }
        return defaultDir
    }

    /// Stable filename for a URL (SHA-256 of its string — avoids path-unsafe chars).
    static func filename(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileURL(for url: URL) -> URL? {
        directory()?.appendingPathComponent(filename(for: url))
    }

    /// Cached bytes for `url`, or nil on miss. Touches the file's modification
    /// date on a hit so pruning keeps recently-used art (LRU-ish).
    public static func data(for url: URL) -> Data? {
        guard let f = fileURL(for: url), let data = try? Data(contentsOf: f) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        return data
    }

    public static func store(_ data: Data, for url: URL) {
        guard !data.isEmpty, let f = fileURL(for: url) else { return }
        try? data.write(to: f, options: .atomic)
    }

    /// Evict least-recently-modified files until the cache is under `limitBytes`.
    /// Cheap to call once per session; safe to run off the main thread.
    public static func prune(limitBytes: Int = 200 * 1024 * 1024) {
        guard let dir = directory() else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys) else { return }

        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for f in files {
            let v = try? f.resourceValues(forKeys: Set(keys))
            let size = v?.fileSize ?? 0
            entries.append((f, size, v?.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > limitBytes else { return }

        // Delete oldest first until we're back under the limit.
        for e in entries.sorted(by: { $0.date < $1.date }) {
            if total <= limitBytes { break }
            try? FileManager.default.removeItem(at: e.url)
            total -= e.size
        }
    }
}
