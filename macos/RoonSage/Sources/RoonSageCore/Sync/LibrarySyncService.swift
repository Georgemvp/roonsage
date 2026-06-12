import AudioAnalysis
import Foundation

/// Walks the Roon Browse hierarchy (Root→Library→Albums→tracks) and
/// upserts every discovered track into the local GRDB database.
actor LibrarySyncService {

    // MARK: - Progress

    public struct Progress: Sendable {
        public var phase: String
        public var albumsCompleted: Int
        public var albumsTotal: Int
        public var tracksFound: Int

        public var fraction: Double {
            albumsTotal > 0 ? Double(albumsCompleted) / Double(albumsTotal) : 0
        }
    }

    // MARK: - Private state

    private let browse: BrowseService
    private let database: DatabaseManager
    private var isCancelled = false

    init(browse: BrowseService, database: DatabaseManager) {
        self.browse = browse
        self.database = database
    }

    // MARK: - Public API

    func cancel() { isCancelled = true }

    /// Walk the library and return the final track count.
    /// `onProgress` is called on the actor's executor; bridge to MainActor in the caller.
    func sync(onProgress: @escaping @Sendable (Progress) -> Void) async throws -> Int {
        isCancelled = false
        let session = "library_sync_\(Int(Date().timeIntervalSince1970))"

        // 1. Root
        onProgress(Progress(phase: "Root openen…", albumsCompleted: 0, albumsTotal: 0, tracksFound: 0))
        let rootItems = try await browse.browseAll(to: nil, sessionKey: session)

        guard !isCancelled else { return 0 }

        // 2. Find Library (handles English and other localisations)
        guard let libraryItem = rootItems.first(where: {
            let t = $0.title.lowercased()
            return t.contains("library") || t.contains("bibliotheek") || t.contains("mediathek")
        }) else {
            throw SyncError.libraryNotFound
        }

        // 3. Browse into Library
        onProgress(Progress(phase: "Bibliotheek openen…", albumsCompleted: 0, albumsTotal: 0, tracksFound: 0))
        let libraryItems = try await browse.browseAll(to: libraryItem.itemKey, sessionKey: session)

        guard !isCancelled else { return 0 }

        // 4. Find Albums section
        guard let albumsItem = libraryItems.first(where: {
            let t = $0.title.lowercased()
            return t.contains("album") || t.contains("alben")
        }) else {
            throw SyncError.albumsNotFound
        }

        // 5. Load all albums (paginated)
        onProgress(Progress(phase: "Albums laden…", albumsCompleted: 0, albumsTotal: 0, tracksFound: 0))
        let albumItems = try await browse.browseAll(to: albumsItem.itemKey, sessionKey: session)
        let totalAlbums = albumItems.count

        guard !isCancelled else { return 0 }

        // 6. Begin (or resume) the sync run. No destructive clear: albums are
        //    replaced one-by-one as they're walked, and rows of vanished albums
        //    are only dropped in finishSyncRun() after a COMPLETE walk. An
        //    interrupted sync (screen lock / app suspend) therefore keeps the
        //    old library intact and resumes by skipping checkpointed albums.
        let run = try database.beginSyncRun()
        if run.resumed {
            onProgress(Progress(
                phase: "Sync hervatten (\(run.completedAlbums.count) albums klaar)…",
                albumsCompleted: 0, albumsTotal: totalAlbums, tracksFound: 0))
        }

        // 7. Walk each album
        var albumsCompleted = 0
        var albumsFailed = 0
        var tracksFound = 0
        var seenThisRun = Set<String>()   // duplicate-edition fingerprints append, not replace

        for album in albumItems {
            guard !isCancelled else { break }
            guard let albumKey = album.itemKey else { continue }

            let fingerprint = Self.albumFingerprint(title: album.title, subtitle: album.subtitle)

            // Already completed in this (interrupted) generation — skip the
            // expensive per-album browse; its rows are still in the DB. Also
            // skips duplicate-edition occurrences of a checkpointed fingerprint:
            // re-walking one would append onto the prior attempt's rows.
            if run.completedAlbums.contains(fingerprint) {
                seenThisRun.insert(fingerprint)
                albumsCompleted += 1
                continue
            }

            let (albumArtist, year) = parseSubtitle(album.subtitle)
            // Compilation detection: "Various Artists" / "Diverse artiesten" etc.
            let isCompilation = albumArtist.map {
                $0.lowercased().hasPrefix("various") || $0.lowercased().hasPrefix("diverse")
            } ?? true

            let trackItems: [BrowseService.Item]
            do {
                trackItems = try await browse.browseAll(to: albumKey, sessionKey: session)
            } catch {
                // Skip albums that fail to load (e.g. unavailable streaming
                // content) — but count them: a walk with failures must not
                // prune, or a flaky connection would shrink the library.
                albumsFailed += 1
                albumsCompleted += 1
                continue
            }

            // Batch-insert all tracks for this album
            var batch: [TrackRecord] = []
            for item in trackItems {
                guard let key = item.itemKey else { continue }
                // Roon navigation rows ("Play Album", "Queue Album", …) have no
                // subtitle — real track rows always do. Without this filter every
                // album contributed a phantom "Play Album" track (mirrors the
                // Python filter in roon_browse.py).
                guard let sub = item.subtitle, !sub.isEmpty else { continue }
                let liveHints = ["live", "concert", "unplugged", "acoustic"]
                let combinedTitle = (item.title + (item.subtitle ?? "")).lowercased()
                let isLive = liveHints.contains { combinedTitle.contains($0) }
                // For compilations Roon Browse returns the track artist in item.subtitle;
                // use it so the match_key aligns with the file-tag artist in the analyzer.
                let (trackArtist, _) = isCompilation ? parseSubtitle(item.subtitle) : (nil, nil)
                let artist = trackArtist ?? albumArtist
                batch.append(TrackRecord(
                    id: key,
                    title: TrackIdentity.stripTrackPrefix(item.title),
                    artist: artist,
                    album: album.title,
                    albumKey: albumKey,
                    year: year,
                    isLive: isLive,
                    matchKey: TrackIdentity.matchKey(artist: artist, album: album.title, title: item.title),
                    imageKey: item.imageKey ?? album.imageKey
                ))
            }

            try database.replaceAlbumTracks(
                batch,
                albumTitle: album.title,
                fingerprint: fingerprint,
                generation: run.generation,
                append: seenThisRun.contains(fingerprint))
            seenThisRun.insert(fingerprint)
            tracksFound += batch.count
            albumsCompleted += 1

            onProgress(Progress(
                phase: "Albums synchroniseren…",
                albumsCompleted: albumsCompleted,
                albumsTotal: totalAlbums,
                tracksFound: tracksFound
            ))
        }

        // 8. Complete walk → now it's safe to drop rows of albums that no
        //    longer exist in Roon and close the generation. On cancel/crash we
        //    skip this, leaving the checkpoints so the next run resumes.
        //    If any album failed to browse we still close the run but skip
        //    the destructive prune: failed albums have no checkpoint this
        //    generation and pruning would delete their still-valid rows.
        if !isCancelled {
            try database.finishSyncRun(generation: run.generation, pruneStale: albumsFailed == 0)
            // Includes rows of resume-skipped albums (tracksFound only counts
            // freshly walked ones).
            tracksFound = try database.trackCount()
        }

        // 9. Genre pass — walk the Roon `genres` hierarchy and map albums → genres.
        //    Non-fatal: a failure here still leaves a fully-synced track library.
        if !isCancelled {
            // Immutable copy — the @Sendable progress closure below must not
            // capture the mutable `tracksFound` var (rejected under -c release).
            let finalTrackCount = tracksFound
            onProgress(Progress(phase: "Genres synchroniseren…", albumsCompleted: totalAlbums, albumsTotal: totalAlbums, tracksFound: finalTrackCount))
            let genreSession = "genre_sync_\(Int(Date().timeIntervalSince1970))"
            do {
                let mapping = try await browse.genreMapping(sessionKey: genreSession) { done, total in
                    onProgress(Progress(
                        phase: "Genres synchroniseren… (\(done)/\(total))",
                        albumsCompleted: totalAlbums, albumsTotal: totalAlbums, tracksFound: finalTrackCount
                    ))
                }
                if !mapping.isEmpty {
                    try database.applyGenreMapping(mapping)
                }
            } catch {
                // Genre taxonomy unavailable — tracks are still usable without it.
            }
        }

        // 10. Record sync timestamp
        try database.setSyncState(key: "last_sync", value: DatabaseManager.isoFormatter.string(from: Date()))

        return tracksFound
    }

    // MARK: - Helpers

    /// Stable album identity across Roon sessions (item_keys are session-scoped
    /// and can't key anything persistent). Title + subtitle ("Artist • Year")
    /// survives reconnects; a same-titled re-release differs by year.
    static func albumFingerprint(title: String, subtitle: String?) -> String {
        "\(title.lowercased())|\((subtitle ?? "").lowercased())"
    }

    private func parseSubtitle(_ subtitle: String?) -> (artist: String?, year: Int?) {
        guard let subtitle, !subtitle.isEmpty else { return (nil, nil) }
        let parts = subtitle.components(separatedBy: "•").map { $0.trimmingCharacters(in: .whitespaces) }
        let artist = parts.first.map { $0.isEmpty ? nil : $0 } ?? nil
        let year = parts.dropFirst().first.flatMap { Int($0.filter(\.isNumber)) }
        return (artist, year)
    }
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case libraryNotFound
    case albumsNotFound

    var errorDescription: String? {
        switch self {
        case .libraryNotFound: "Kon de bibliotheek niet vinden in de Roon Browse-hiërarchie."
        case .albumsNotFound:  "Kon de albumsectie niet vinden in de Roon-bibliotheek."
        }
    }
}
