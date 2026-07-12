import Foundation

// MARK: - Sonic Journeys
//
// Three Plexamp-style "radio station types", renamed:
//   • Album Radio  — an endless station seeded on an album      (reuses startRadio)
//   • Time Machine — a finite chronological journey old → new    (reuses curateTracks)
//   • The Bridge   — an A→B path between two tracks              (SongPaths; UI reuses SongPathsView)
//
// Journeys are on-demand stations with their own id prefixes ("album:", …). An
// unknown prefix falls through `candidateGate(for:)` → nil (no measured gate),
// exactly like "track:", so no RadioCategory wiring is needed.

@MainActor
extension RoonClient {

    // MARK: Album Radio

    /// Endless station grown around one album's analyzed tracks — like an artist
    /// radio, but the centroid is the album. Composes with a DJ persona.
    /// `buildRadioCandidates` intersects the seeds with the analyzed library, so
    /// unanalyzed album rows are dropped; we check for at least one here to give a
    /// clean message instead of an empty station.
    public func startAlbumRadio(albumKey: String, title: String, artist: String?,
                                imageKey: String? = nil, zoneID: String, djMode: DJMode? = nil) async {
        guard let db = database else {
            reportError("Album-radio mislukt — geen bibliotheek beschikbaar.")
            return
        }
        let rows = (try? await db.tracksForAlbum(albumKey)) ?? []
        let lib = await radioLibrary()
        let analyzed = Set(lib.map(\.id))
        let seedIds = rows.map(\.id).filter { analyzed.contains($0) }
        guard !seedIds.isEmpty else {
            reportError("Dit album is nog niet geanalyseerd — album-radio kan nog niet.")
            return
        }
        let img = imageKey ?? rows.first(where: { !($0.imageKey ?? "").isEmpty })?.imageKey
        let radio = SonicRadio(id: "album:\(albumKey)", artist: title, imageKey: img,
                               trackCount: seedIds.count, seedIds: seedIds)
        await startRadio(radio, zoneID: zoneID, djMode: djMode)
    }

    // MARK: Time Machine

    /// A finite journey old → new: the analyzed library sampled across the decades
    /// it spans, ordered by release year. Year comes from file tags (Roon Browse
    /// has none), so untagged tracks can't take part — the returned count reflects
    /// that. Play via `curateTracks` (a journey has an end, like The Bridge).
    public func buildTimeMachine(count: Int = 40) async -> [TrackRecord] {
        guard let db = database else { return [] }
        let lib = await radioLibrary()
        guard !lib.isEmpty else { return [] }
        let years = (try? await db.yearByMatchKey()) ?? [:]
        return Self.timeMachineOrder(lib, years: years, count: count)
            .map { TrackRecord(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album) }
    }

    /// Pure + deterministic (testable without a DB): keep only dated tracks, take
    /// an even spread across the decades they span, then order the whole result
    /// ascending by year. No RNG — the ordering is assertable. Tracks without a
    /// plausible year are excluded (a chronological journey needs a date).
    nonisolated static func timeMachineOrder(
        _ lib: [DatabaseManager.SonicTrack], years: [String: Int], count: Int
    ) -> [DatabaseManager.SonicTrack] {
        guard count > 0 else { return [] }
        let dated: [(t: DatabaseManager.SonicTrack, year: Int)] = lib.compactMap { t in
            guard let y = years[t.matchKey], isPlausibleYear(y) else { return nil }
            return (t, y)
        }
        guard !dated.isEmpty else { return [] }

        // Even spread across decades so the journey actually travels through time
        // instead of clumping in the best-tagged era.
        var byDecade: [Int: [(t: DatabaseManager.SonicTrack, year: Int)]] = [:]
        for d in dated { byDecade[(d.year / 10) * 10, default: []].append(d) }
        let decades = byDecade.keys.sorted()
        let perDecade = max(1, count / decades.count)

        var picked: [(t: DatabaseManager.SonicTrack, year: Int)] = []
        for dec in decades {
            let sorted = byDecade[dec]!.sorted { ($0.year, $0.t.id) < ($1.year, $1.t.id) }
            picked.append(contentsOf: sorted.prefix(perDecade))
        }
        picked.sort { ($0.year, $0.t.id) < ($1.year, $1.t.id) }
        return Array(picked.prefix(count)).map(\.t)
    }

    // MARK: Qobuz mirror (user-initiated)

    /// Save a journey's tracklist to a Qobuz playlist under the shared
    /// "RoonSage · " namespace (find-or-create by exact name, rename-in-place via a
    /// known id). A one-shot user action — no reconcile, like saving a playlist.
    /// Returns true when Qobuz accepted the sync.
    @discardableResult
    public func syncJourneyToQobuz(title: String, description: String,
                                   tracks: [TrackRecord]) async -> Bool {
        guard !tracks.isEmpty,
              let email = KeychainStore.load(key: "qobuz_email"), !email.isEmpty,
              let pw = KeychainStore.load(key: "qobuz_password"), !pw.isEmpty else { return false }
        let payload = tracks.map { (title: $0.title, artist: $0.artist, album: $0.album) }
        let result = await QobuzClient.shared.syncPlaylist(
            name: Self.qobuzPlaylistName(for: title), description: description,
            tracks: payload, email: email, password: pw)
        return result != nil
    }
}
