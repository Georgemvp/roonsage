import AudioAnalysis
import Foundation
import Observation
import RoonProtocol

/// Wire DTO a client POSTs to `/playlists` to save a new playlist.
public struct SavePlaylistRequest: Codable, Sendable {
    public var name: String
    public var tracks: [TrackRecord]
    public init(name: String, tracks: [TrackRecord]) {
        self.name = name; self.tracks = tracks
    }
}

@MainActor
extension RoonClient {
    // MARK: - Saved playlists
    //
    // Playlists live on the server-of-record so every client app shows the same
    // set: the always-on server build (`.direct`) reads/writes its DB directly;
    // the Mac/iOS client apps (`.server`) go over HTTP to the share server.

    /// Fire-and-forget save (view callers don't use the row id) — keeps the call
    /// site synchronous while the DB write runs off-main.
    public func savePlaylist(name: String, tracks: [TrackRecord]) {
        Task { _ = await savePlaylistReturningID(name: name, tracks: tracks) }
    }

    /// Save and return the new row id — for the MCP tool, which reports it.
    public func savePlaylistReturningID(name: String, tracks: [TrackRecord]) async -> Int64? {
        if isRemote { return await postPlaylist(SavePlaylistRequest(name: name, tracks: tracks)) }
        return try? await database?.savePlaylist(name: name, tracks: tracks)
    }

    public func playlists() async -> [DatabaseManager.PlaylistSummary] {
        if isRemote { return await fetchRemotePlaylists() }
        guard let db = database else { return [] }
        return (try? await db.listPlaylists()) ?? []
    }

    public func playlistTracks(id: Int64) async -> [TrackRecord] {
        if isRemote { return await fetchRemotePlaylistTracks(id: id) }
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
        if isRemote { Task { await deleteRemotePlaylist(id: id) }; return }
        Task { try? await database?.deletePlaylist(id: id) }
    }

    // MARK: Remote (client app → share server)

    private func postPlaylist(_ req: SavePlaylistRequest) async -> Int64? {
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/playlists") else {
            reportError("Geen verbinding met de RoonSage-server.")
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(req)
        authorizeShareRequest(&request)
        request.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            reportError("Playlist opslaan mislukt — is de RoonSage-server bereikbaar?")
            return nil
        }
        struct Reply: Decodable { let id: Int64 }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.id
    }

    private func deleteRemotePlaylist(id: Int64) async {
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/playlists?id=\(id)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        authorizeShareRequest(&req)
        req.timeoutInterval = 8
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200 { return }
        reportError("Playlist verwijderen mislukt — is de RoonSage-server bereikbaar?")
    }

    private func fetchRemotePlaylists() async -> [DatabaseManager.PlaylistSummary] {
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/playlists") else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 8
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode([DatabaseManager.PlaylistSummary].self, from: data) else { return [] }
        return list
    }

    private func fetchRemotePlaylistTracks(id: Int64) async -> [TrackRecord] {
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/playlist-tracks?id=\(id)") else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 8
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let tracks = try? JSONDecoder().decode([TrackRecord].self, from: data) else { return [] }
        return tracks
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
