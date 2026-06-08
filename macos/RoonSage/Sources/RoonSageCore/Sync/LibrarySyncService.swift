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
        onProgress(Progress(phase: "Navigating root…", albumsCompleted: 0, albumsTotal: 0, tracksFound: 0))
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
        onProgress(Progress(phase: "Opening library…", albumsCompleted: 0, albumsTotal: 0, tracksFound: 0))
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
        onProgress(Progress(phase: "Loading albums…", albumsCompleted: 0, albumsTotal: 0, tracksFound: 0))
        let albumItems = try await browse.browseAll(to: albumsItem.itemKey, sessionKey: session)
        let totalAlbums = albumItems.count

        guard !isCancelled else { return 0 }

        // 6. Clear stale data
        try database.clearTracks()

        // 7. Walk each album
        var albumsCompleted = 0
        var tracksFound = 0

        for album in albumItems {
            guard !isCancelled else { break }
            guard let albumKey = album.itemKey else { continue }

            let (artist, year) = parseSubtitle(album.subtitle)

            let trackItems: [BrowseService.Item]
            do {
                trackItems = try await browse.browseAll(to: albumKey, sessionKey: session)
            } catch {
                // Skip albums that fail to load (e.g. unavailable streaming content)
                albumsCompleted += 1
                continue
            }

            // Batch-insert all tracks for this album
            var batch: [TrackRecord] = []
            for item in trackItems {
                guard let key = item.itemKey else { continue }
                let liveHints = ["live", "concert", "unplugged", "acoustic"]
                let combinedTitle = (item.title + (item.subtitle ?? "")).lowercased()
                let isLive = liveHints.contains { combinedTitle.contains($0) }
                batch.append(TrackRecord(
                    id: key,
                    title: item.title,
                    artist: artist,
                    album: album.title,
                    albumKey: albumKey,
                    year: year,
                    isLive: isLive
                ))
            }

            try database.upsertTracks(batch)
            tracksFound += batch.count
            albumsCompleted += 1

            onProgress(Progress(
                phase: "Syncing albums…",
                albumsCompleted: albumsCompleted,
                albumsTotal: totalAlbums,
                tracksFound: tracksFound
            ))
        }

        // 8. Genre pass — walk the Roon `genres` hierarchy and map albums → genres.
        //    Non-fatal: a failure here still leaves a fully-synced track library.
        if !isCancelled {
            // Immutable copy — the @Sendable progress closure below must not
            // capture the mutable `tracksFound` var (rejected under -c release).
            let finalTrackCount = tracksFound
            onProgress(Progress(phase: "Syncing genres…", albumsCompleted: totalAlbums, albumsTotal: totalAlbums, tracksFound: finalTrackCount))
            let genreSession = "genre_sync_\(Int(Date().timeIntervalSince1970))"
            do {
                let mapping = try await browse.genreMapping(sessionKey: genreSession) { done, total in
                    onProgress(Progress(
                        phase: "Syncing genres… (\(done)/\(total))",
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

        // 9. Record sync timestamp
        try database.setSyncState(key: "last_sync", value: ISO8601DateFormatter().string(from: Date()))

        return tracksFound
    }

    // MARK: - Helpers

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
        case .libraryNotFound: "Could not find Library in Roon Browse hierarchy."
        case .albumsNotFound:  "Could not find Albums section in Roon Library."
        }
    }
}
