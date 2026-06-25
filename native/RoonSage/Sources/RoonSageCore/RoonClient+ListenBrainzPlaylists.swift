import Foundation

#if os(macOS)
/// Daily import of the user's ListenBrainz playlists into the server's playlist
/// library. Runs only on the always-on server build; the synced playlists then
/// reach every client (incl. the iOS remote's Playlists tab) over GET /playlists.
extension RoonClient {

    /// Source-scoped prefix for the `external_id` of imported playlists, so the
    /// reconcile only ever touches ListenBrainz imports.
    static let lbPlaylistSource = "listenbrainz:"

    /// Name prefix for the Qobuz copies, so they're recognisable and reconciled
    /// in place (find-or-create by exact name) instead of duplicating each day.
    static let lbQobuzNamePrefix = "ListenBrainz · "

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
            return
        }

        if lbQobuzSyncEnabled {
            await mirrorPlaylistsToQobuz(imported)
        }
    }

    /// Mirror the imported ListenBrainz playlists to Qobuz, one playlist each,
    /// under a recognisable "ListenBrainz · …" name. `syncPlaylist` finds-or-
    /// creates by exact name and replaces contents, so daily runs update in place
    /// rather than duplicating; orphans (playlists gone upstream) are removed.
    private func mirrorPlaylistsToQobuz(_ playlists: [DatabaseManager.ExternalPlaylist]) async {
        // Never reconcile to nothing on an empty import (a transient LB hiccup
        // shouldn't wipe the Qobuz copies).
        guard !playlists.isEmpty else { return }
        guard let email = KeychainStore.load(key: "qobuz_email"), !email.isEmpty,
              let password = KeychainStore.load(key: "qobuz_password"), !password.isEmpty else {
            lbPlaylistSyncStatus += " (Qobuz niet ingesteld — niet naar Qobuz gesynct.)"
            return
        }

        var synced = 0
        var kept = Set<String>()
        for pl in playlists {
            let name = Self.lbQobuzNamePrefix + pl.name
            kept.insert(name)
            let tracks = pl.tracks.map { (title: $0.title, artist: $0.artist, album: $0.album) }
            let result = await QobuzClient.shared.syncPlaylist(
                name: name,
                description: "Gesynchroniseerd vanuit ListenBrainz door RoonSage",
                tracks: tracks,
                email: email, password: password
            )
            if result != nil { synced += 1 }
        }

        // Reconcile: drop Qobuz copies of playlists that no longer exist upstream.
        _ = await QobuzClient.shared.deleteRadioOrphans(
            keep: kept, namePrefix: Self.lbQobuzNamePrefix, email: email, password: password
        )

        lbPlaylistSyncStatus += " \(synced) naar Qobuz."
    }
}
#endif
