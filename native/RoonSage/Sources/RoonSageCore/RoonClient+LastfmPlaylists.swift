import Foundation

#if os(macOS)
/// Daily synthesis of "playlists" from Last.fm. Last.fm has no real playlist API
/// (the feature was discontinued years ago), so we derive playlists from the
/// user's top tracks per period and reconcile them into the playlist library —
/// the same machinery as the ListenBrainz import, including the Qobuz mirror.
extension RoonClient {

    /// Source-scoped prefix for the `external_id` of Last.fm-derived playlists.
    static let lastfmPlaylistSource = "lastfm:"
    /// Name prefix for the Qobuz copies.
    static let lastfmQobuzNamePrefix = "Last.fm · "

    /// Top-track periods turned into playlists, with their display labels.
    static let lastfmPlaylistPeriods: [(period: LastfmClient.Period, label: String)] = [
        (.week,    "Laatste 7 dagen"),
        (.month,   "Laatste maand"),
        (.year,    "Laatste jaar"),
        (.overall, "Aller tijden"),
    ]

    func startLastfmPlaylistSync(initialDelay: UInt64 = 20_000_000_000) {
        guard lastfmPlaylistSyncTask == nil else { return }
        lastfmPlaylistSyncTask = Task { [weak self] in
            if initialDelay > 0 { try? await Task.sleep(nanoseconds: initialDelay) }
            while !Task.isCancelled {
                await self?.runLastfmPlaylistSync()
                try? await Task.sleep(nanoseconds: UInt64(24 * 3600) * 1_000_000_000)
            }
        }
    }

    func stopLastfmPlaylistSync() {
        lastfmPlaylistSyncTask?.cancel()
        lastfmPlaylistSyncTask = nil
    }

    /// Pull the user's Last.fm top tracks per period and reconcile them into the
    /// playlist library. Idempotent: re-running replaces the derived set.
    func runLastfmPlaylistSync() async {
        guard lastfmPlaylistSyncEnabled else { return }
        guard let db = database else { return }
        guard lastfmConfigured else {
            lastfmPlaylistSyncStatus = "Last.fm niet gekoppeld (gebruikersnaam + API-sleutel)."
            return
        }

        lastfmPlaylistSyncStatus = "Bezig met synchroniseren…"

        var imported: [DatabaseManager.ExternalPlaylist] = []
        for (period, label) in Self.lastfmPlaylistPeriods {
            let top = await lastfmTopTracks(period: period, limit: 50)
            let records = top.compactMap { item -> TrackRecord? in
                guard !item.name.isEmpty else { return nil }
                return TrackRecord(id: "", title: item.name, artist: item.artist, album: nil)
            }
            guard !records.isEmpty else { continue }
            imported.append(.init(
                externalID: "\(Self.lastfmPlaylistSource)top:\(period.rawValue)",
                name: "Last.fm Top · \(label)",
                tracks: records
            ))
        }

        // A failed/rate-limited/unauthorized Last.fm request also yields an empty
        // list, indistinguishable from a genuinely empty period. If NOTHING came
        // back across all periods, treat it as a transient outage and keep the
        // last good playlists rather than pruning them to nothing. (When at least
        // one period has data, connectivity is proven, so an empty period is real
        // and is pruned as expected.)
        guard !imported.isEmpty else {
            lastfmPlaylistSyncStatus = "Last.fm gaf niets terug — vorige playlists behouden."
            return
        }

        do {
            try await db.syncExternalPlaylists(sourcePrefix: Self.lastfmPlaylistSource, playlists: imported)
            lastfmPlaylistSyncStatus = "\(imported.count) playlist(s) gesynchroniseerd."
        } catch {
            lastfmPlaylistSyncStatus = "Synchronisatie mislukt."
            Log.warning("Last.fm playlist sync failed: \(error)", category: .network)
            return
        }

        if lastfmQobuzSyncEnabled {
            let n = await mirrorExternalPlaylistsToQobuz(imported, namePrefix: Self.lastfmQobuzNamePrefix)
            lastfmPlaylistSyncStatus += n < 0 ? " (Qobuz niet ingesteld.)" : " \(n) naar Qobuz."
        }
    }
}
#endif
