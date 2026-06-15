import AudioAnalysis
import Foundation
import Observation
import RoonProtocol

@MainActor
extension RoonClient {
    // MARK: - Saved playlists

    /// Fire-and-forget save (view callers don't use the row id) — keeps the call
    /// site synchronous while the DB write runs off-main.
    public func savePlaylist(name: String, tracks: [TrackRecord]) {
        Task { try? await database?.savePlaylist(name: name, tracks: tracks) }
    }

    /// Save and return the new row id — for the MCP tool, which reports it.
    public func savePlaylistReturningID(name: String, tracks: [TrackRecord]) async -> Int64? {
        try? await database?.savePlaylist(name: name, tracks: tracks)
    }

    public func playlists() async -> [DatabaseManager.PlaylistSummary] {
        guard let db = database else { return [] }
        return (try? await db.listPlaylists()) ?? []
    }

    public func playlistTracks(id: Int64) async -> [TrackRecord] {
        guard let db = database else { return [] }
        return (try? await db.playlistTracks(id: id)) ?? []
    }

    /// Saved tracks re-resolved to the current library (so album art / item_keys
    /// are populated). Falls back to the stored rows for any that don't resolve.
    public func playlistTracksForDisplay(id: Int64) async -> [TrackRecord] {
        let saved = await playlistTracks(id: id)
        guard !saved.isEmpty else { return [] }
        let resolved = (try? await database?.resolveCurrentTracks(saved)) ?? []
        guard resolved.count == saved.count else { return saved }
        return resolved
    }

    public func deletePlaylist(id: Int64) {
        Task { try? await database?.deletePlaylist(id: id) }
    }

    /// Resolve a saved playlist to current item_keys and play it. Returns the
    /// number of tracks that resolved + started.
    @discardableResult
    public func playPlaylist(id: Int64, zoneID: String) async -> Int {
        let saved = await playlistTracks(id: id)
        guard !saved.isEmpty else { return 0 }
        let current = (try? await database?.resolveCurrentTracks(saved)) ?? []
        guard !current.isEmpty else { return 0 }
        await curateTracks(current, zoneID: zoneID)
        return current.count
    }

    public func transferZone(fromZoneID: String, toZoneID: String) async {
        if isRemote { var c = RemoteCommand("transferZone"); c.fromZoneID = fromZoneID; c.toZoneID = toZoneID; await remote(c); return }
        await runAction("Zone-overdracht") { _ = try await $0.transferZone(fromZoneID: fromZoneID, toZoneID: toZoneID) }
    }

    // MARK: - Recommendation history

    /// Fire-and-forget save (callers don't use the row id) — keeps the call site
    /// synchronous while the DB write runs off-main.
    public func saveRecommendation(prompt: String, albums: [DatabaseManager.AlbumResult]) {
        Task { try? await database?.saveRecommendation(prompt: prompt, albums: albums) }
    }

    public func recommendations() async -> [DatabaseManager.RecommendationSummary] {
        guard let db = database else { return [] }
        return (try? await db.listRecommendations()) ?? []
    }

    public func recommendationAlbums(id: Int64) async -> [DatabaseManager.AlbumResult] {
        guard let db = database else { return [] }
        return (try? await db.recommendationAlbums(id: id)) ?? []
    }

    public func deleteRecommendation(id: Int64) {
        Task { try? await database?.deleteRecommendation(id: id) }
    }

}
