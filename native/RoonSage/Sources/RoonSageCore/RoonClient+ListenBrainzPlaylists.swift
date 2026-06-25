import Foundation

#if os(macOS)
/// Daily import of the user's ListenBrainz playlists into the server's playlist
/// library. Runs only on the always-on server build; the synced playlists then
/// reach every client (incl. the iOS remote's Playlists tab) over GET /playlists.
extension RoonClient {

    /// Source-scoped prefix for the `external_id` of imported playlists, so the
    /// reconcile only ever touches ListenBrainz imports.
    static let lbPlaylistSource = "listenbrainz:"

    func startListenBrainzPlaylistSync(initialDelay: UInt64 = 15_000_000_000) {
        guard lbPlaylistSyncTask == nil else { return }
        lbPlaylistSyncTask = Task { [weak self] in
            if initialDelay > 0 { try? await Task.sleep(nanoseconds: initialDelay) }
            while !Task.isCancelled {
                await self?.runListenBrainzPlaylistSync()
                // Daily cadence; cancelled cleanly when the user turns the toggle off.
                try? await Task.sleep(nanoseconds: UInt64(24 * 3600) * 1_000_000_000)
            }
        }
    }

    func stopListenBrainzPlaylistSync() {
        lbPlaylistSyncTask?.cancel()
        lbPlaylistSyncTask = nil
    }

    /// Pull every ListenBrainz playlist (the user's own + "created for you") and
    /// reconcile them into the playlist library. Idempotent: re-running replaces
    /// the imported set rather than duplicating it.
    func runListenBrainzPlaylistSync() async {
        guard lbPlaylistSyncEnabled else { return }
        guard let db = database else { return }
        guard let token = KeychainStore.load(key: "listenbrainz_token"), !token.isEmpty else {
            lbPlaylistSyncStatus = "Geen ListenBrainz-token ingesteld."
            return
        }

        lbPlaylistSyncStatus = "Bezig met synchroniseren…"
        let lb = ListenBrainzClient.shared

        guard let username = await lb.resolveUsername(token: token) else {
            lbPlaylistSyncStatus = "ListenBrainz-token ongeldig."
            return
        }

        let refs = await lb.userPlaylists(username: username, token: token)
        var imported: [DatabaseManager.ExternalPlaylist] = []
        for ref in refs {
            let tracks = await lb.playlistTracks(mbid: ref.mbid, token: token)
            guard !tracks.isEmpty else { continue }
            let records = tracks.map {
                TrackRecord(id: "", title: $0.title, artist: $0.artist, album: $0.album)
            }
            imported.append(.init(
                externalID: Self.lbPlaylistSource + ref.mbid,
                name: ref.title,
                tracks: records
            ))
        }

        do {
            try await db.syncExternalPlaylists(sourcePrefix: Self.lbPlaylistSource, playlists: imported)
            lbPlaylistSyncStatus = imported.isEmpty
                ? "Geen ListenBrainz-playlists gevonden."
                : "\(imported.count) playlist(s) gesynchroniseerd."
        } catch {
            lbPlaylistSyncStatus = "Synchronisatie mislukt."
            Log.warning("ListenBrainz playlist sync failed: \(error)", category: .network)
        }
    }
}
#endif
