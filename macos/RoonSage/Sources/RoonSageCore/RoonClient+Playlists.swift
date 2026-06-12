import AudioAnalysis
import Foundation
import Observation
import RoonProtocol

@MainActor
extension RoonClient {
    // MARK: - Saved playlists

    @discardableResult
    public func savePlaylist(name: String, tracks: [TrackRecord]) -> Int64? {
        try? database?.savePlaylist(name: name, tracks: tracks)
    }

    public func playlists() async -> [DatabaseManager.PlaylistSummary] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.listPlaylists()) ?? [] }.value
    }

    public func playlistTracks(id: Int64) async -> [TrackRecord] {
        guard let db = database else { return [] }
        return await Task.detached { (try? db.playlistTracks(id: id)) ?? [] }.value
    }

    /// Saved tracks re-resolved to the current library (so album art / item_keys
    /// are populated). Falls back to the stored rows for any that don't resolve.
    public func playlistTracksForDisplay(id: Int64) async -> [TrackRecord] {
        let saved = await playlistTracks(id: id)
        guard !saved.isEmpty else { return [] }
        let resolved = (try? database?.resolveCurrentTracks(saved)) ?? []
        guard resolved.count == saved.count else { return saved }
        return resolved
    }

    public func deletePlaylist(id: Int64) {
        try? database?.deletePlaylist(id: id)
    }

    /// Resolve a saved playlist to current item_keys and play it. Returns the
    /// number of tracks that resolved + started.
    @discardableResult
    public func playPlaylist(id: Int64, zoneID: String) async -> Int {
        let saved = await playlistTracks(id: id)
        guard !saved.isEmpty else { return 0 }
        let current = (try? database?.resolveCurrentTracks(saved)) ?? []
        guard !current.isEmpty else { return 0 }
        await curateTracks(current, zoneID: zoneID)
        return current.count
    }

    public func transferZone(fromZoneID: String, toZoneID: String) async {
        await runAction("Zone-overdracht") { _ = try await $0.transferZone(fromZoneID: fromZoneID, toZoneID: toZoneID) }
    }

}
