import Foundation

/// In-memory cache of the analyzed sonic library (C4).
///
/// `DatabaseManager.sonicTracks()` joins tracks ↔ features and JSON-parses the
/// tag column for the whole analyzed library — expensive at 30k tracks, and it
/// used to run on *every* similarity query (Live DJ re-ran it per track
/// change). The rows only change when features sync or the library re-syncs,
/// so cache the array once and invalidate on those two events.
///
/// Single-flight: concurrent first callers share one detached load instead of
/// each hitting SQLite.
public actor SonicLibraryCache {
    private var cached: [DatabaseManager.SonicTrack]?
    private var inFlight: Task<[DatabaseManager.SonicTrack], Never>?

    public init() {}

    /// The analyzed library, loading (off-main) and caching on first use.
    public func tracks(from db: DatabaseManager) async -> [DatabaseManager.SonicTrack] {
        if let cached { return cached }
        if let inFlight { return await inFlight.value }
        let load = Task.detached(priority: .userInitiated) {
            (try? db.sonicTracks()) ?? []
        }
        inFlight = load
        let result = await load.value
        cached = result
        inFlight = nil
        return result
    }

    /// Drop the cache; the next `tracks(from:)` reloads from SQLite.
    /// Call after a feature sync or library sync.
    public func invalidate() {
        cached = nil
        inFlight = nil
    }
}
