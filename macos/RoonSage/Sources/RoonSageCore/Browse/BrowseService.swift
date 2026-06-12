import Foundation
import RoonProtocol

/// Serialises all Roon Browse API calls through an actor.
/// Concurrent browse calls on the same hierarchy corrupt the session —
/// this mirrors Python's `_browse_lock` pattern.
actor BrowseService {

    private let transport: RoonTransport
    private let pageSize = RoonProtocolConstants.pageSize

    // MARK: - Types

    struct Item: Sendable {
        let title: String
        let subtitle: String?
        let itemKey: String?
        let hint: String?
        let imageKey: String?

        init(from dict: [String: Any]) {
            title    = dict["title"]     as? String ?? ""
            subtitle = dict["subtitle"]  as? String
            itemKey  = dict["item_key"]  as? String
            hint     = dict["hint"]      as? String
            imageKey = dict["image_key"] as? String
        }
    }

    enum BrowseError: Error {
        case noList
        case transport(Error)
    }

    init(transport: RoonTransport) {
        self.transport = transport
    }

    // MARK: - Core calls

    /// Send a browse request and return the raw response body.
    func browse(
        hierarchy: String = "browse",
        itemKey: String? = nil,
        sessionKey: String,
        popAll: Bool = false
    ) async throws -> [String: Any] {
        var body: [String: Any] = [
            "hierarchy": hierarchy,
            "multi_session_key": sessionKey
        ]
        if let itemKey { body["item_key"] = itemKey }
        if popAll { body["pop_all"] = true }
        return try await transport.request("\(RoonService.browse)/browse", body: body)
    }

    /// Load a page of items from the current browse position.
    func load(
        hierarchy: String = "browse",
        sessionKey: String,
        offset: Int = 0,
        count: Int
    ) async throws -> [Item] {
        let body: [String: Any] = [
            "hierarchy": hierarchy,
            "multi_session_key": sessionKey,
            "offset": offset,
            "count": count,
            "set_display_offset": offset
        ]
        let resp = try await transport.request("\(RoonService.browse)/load", body: body)
        return (resp["items"] as? [[String: Any]] ?? []).map(Item.init)
    }

    // MARK: - Convenience

    /// Browse into `itemKey` and return the total list count.
    func navigate(
        to itemKey: String?,
        sessionKey: String,
        hierarchy: String = "browse",
        popAll: Bool = false
    ) async throws -> Int {
        let resp = try await browse(hierarchy: hierarchy, itemKey: itemKey, sessionKey: sessionKey, popAll: popAll)
        guard let list = resp["list"] as? [String: Any],
              let count = list["count"] as? Int else {
            throw BrowseError.noList
        }
        return count
    }

    /// Browse with a zone context — used for playback actions.
    func browseForPlayback(
        itemKey: String?,
        zoneID: String,
        sessionKey: String
    ) async throws -> [String: Any] {
        var body: [String: Any] = [
            "hierarchy": "browse",
            "zone_or_output_id": zoneID,
            "multi_session_key": sessionKey
        ]
        if let itemKey { body["item_key"] = itemKey }
        return try await transport.request("\(RoonService.browse)/browse", body: body)
    }

    /// Play a library item by its browse item_key.
    /// action: "play_now" | "queue" | "add_next"
    func playByBrowse(itemKey: String, zoneID: String, action: String = "play_now") async throws {
        // Synthetic keys carry artist::title and are resolved by a fresh search
        // at play time:
        //  - `qobuz_search::` — global-search item_keys are ephemeral (mirrors
        //    the Python handling in roon_playback.play_tracks).
        //  - `import::` — library rows imported from another device; the source
        //    Mac's item_keys are session-scoped and meaningless here.
        if itemKey.hasPrefix(Self.qobuzSearchPrefix) || itemKey.hasPrefix(Self.importPrefix) {
            let parts = itemKey.components(separatedBy: "::")
            let artist = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
            let title  = parts.count > 2 ? (parts[2].removingPercentEncoding ?? parts[2]) : ""
            _ = try? await playViaSearch(artist: artist, title: title, zoneID: zoneID, action: action)
            return
        }

        let sessionKey = "curate_\(zoneID)"
        let resp = try await browseForPlayback(itemKey: itemKey, zoneID: zoneID, sessionKey: sessionKey)

        guard let list = resp["list"] as? [String: Any],
              let count = list["count"] as? Int, count > 0 else { return }

        let items = try await load(hierarchy: "browse", sessionKey: sessionKey, offset: 0, count: min(count, 20))

        let targetTitle: String
        switch action {
        case "queue":    targetTitle = "Queue"
        case "add_next": targetTitle = "Add Next"
        default:         targetTitle = "Play Now"
        }

        let actionItem = items.first(where: {
            $0.hint == "action" && $0.title.localizedCaseInsensitiveContains(targetTitle)
        }) ?? items.first(where: { $0.hint == "action" })

        guard let key = actionItem?.itemKey else { return }
        _ = try? await browseForPlayback(itemKey: key, zoneID: zoneID, sessionKey: sessionKey)
    }

    /// Browse into `itemKey` and load ALL items, auto-paginating.
    func browseAll(
        to itemKey: String?,
        sessionKey: String,
        hierarchy: String = "browse",
        popAll: Bool = false
    ) async throws -> [Item] {
        let total = try await navigate(to: itemKey, sessionKey: sessionKey, hierarchy: hierarchy, popAll: popAll)
        guard total > 0 else { return [] }

        var result: [Item] = []
        var offset = 0
        while offset < total {
            let batch = try await load(
                hierarchy: hierarchy,
                sessionKey: sessionKey,
                offset: offset,
                count: min(pageSize, total - offset)
            )
            result.append(contentsOf: batch)
            offset += batch.count
            if batch.isEmpty { break }
        }
        return result
    }

    // MARK: - Genre mapping

    /// Walk the Roon `genres` hierarchy and return albumTitle(lowercased) → [genre].
    ///
    /// Mirrors the Python `_get_genre_mapping`: top-level genres only (sub-genres
    /// skipped for speed), each genre's "Albums" sub-list paginated, albums matched
    /// back to tracks by title. Roon item_keys are session-ephemeral, so the genre
    /// root is re-popped (`pop_all`) before resolving each genre's fresh key.
    func genreMapping(
        sessionKey: String,
        onProgress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async throws -> [String: [String]] {
        let genreItems = try await browseAll(to: nil, sessionKey: sessionKey, hierarchy: "genres", popAll: true)
        let genreNames = genreItems.map(\.title).filter { !$0.isEmpty }

        var mapping: [String: [String]] = [:]

        for (idx, genreName) in genreNames.enumerated() {
            do {
                // Re-pop to the genres root and resolve a fresh item_key for this genre.
                let fresh = try await browseAll(to: nil, sessionKey: sessionKey, hierarchy: "genres", popAll: true)
                guard let genreItem = fresh.first(where: { $0.title == genreName }),
                      let genreKey = genreItem.itemKey else { continue }

                let contents = try await browseAll(to: genreKey, sessionKey: sessionKey, hierarchy: "genres")

                // Roon sometimes auto-navigates directly into the Albums list
                // (when a genre has only one sub-list). Distinguish the two cases:
                // • Sub-category items ("Albums", "Top Tracks") have no imageKey.
                // • Real album items have imageKey set (album art).
                let albumItems: [Item]
                let looksLikeAlbums = contents.contains { $0.imageKey != nil }
                if looksLikeAlbums {
                    // Already at album level (auto-navigated).
                    albumItems = contents
                } else if let albumsItem = contents.first(where: {
                    $0.title.lowercased().contains("album") && $0.hint == "list"
                }), let albumsKey = albumsItem.itemKey {
                    // Sub-category view — navigate into "Albums".
                    albumItems = try await browseAll(to: albumsKey, sessionKey: sessionKey, hierarchy: "genres")
                } else {
                    continue
                }

                for album in albumItems {
                    let key = album.title.trimmingCharacters(in: .whitespaces).lowercased()
                    guard !key.isEmpty else { continue }
                    if mapping[key] == nil { mapping[key] = [] }
                    if !mapping[key]!.contains(genreName) { mapping[key]!.append(genreName) }
                }
            } catch {
                // Skip genres that fail to load; keep going.
            }
            onProgress?(idx + 1, genreNames.count)
        }
        return mapping
    }

    // MARK: - Qobuz / global search

    static let qobuzSearchPrefix = "qobuz_search::"
    /// Library rows imported from another device (DatabaseManager.importKeyPrefix).
    static let importPrefix = DatabaseManager.importKeyPrefix

    struct SearchResult: Sendable {
        let title: String
        let artist: String?
        let album: String?
        /// `qobuz_search::<enc-artist>::<enc-title>` — re-resolved at play time.
        let syntheticKey: String
    }

    private static let trackSectionWords = ["track", "song", "nummer", "titre", "titel"]

    private func isTrackSection(_ title: String) -> Bool {
        let t = title.lowercased()
        return Self.trackSectionWords.contains { t.contains($0) }
    }

    private func encodeKeyPart(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// One step of a `hierarchy: "search"` browse. `input` triggers a fresh
    /// search (with `pop_all`); `itemKey` navigates into a result.
    @discardableResult
    private func searchStep(input: String? = nil, itemKey: String? = nil, zoneID: String? = nil, sessionKey: String) async throws -> [String: Any] {
        var body: [String: Any] = ["hierarchy": "search", "multi_session_key": sessionKey]
        if let input { body["input"] = input; body["pop_all"] = true }
        if let itemKey { body["item_key"] = itemKey }
        if let zoneID { body["zone_or_output_id"] = zoneID }
        return try await transport.request("\(RoonService.browse)/browse", body: body)
    }

    private func searchLoad(sessionKey: String, count: Int) async throws -> [Item] {
        try await load(hierarchy: "search", sessionKey: sessionKey, offset: 0, count: count)
    }

    /// Global Roon search (covers Qobuz). Returns tracks carrying synthetic keys
    /// so playback re-searches instead of trusting the ephemeral search key.
    func searchGlobal(query: String, limit: Int = 20) async throws -> [SearchResult] {
        let session = "qobuz_search"
        _ = try await searchStep(input: query, sessionKey: session)
        var items = try await searchLoad(sessionKey: session, count: 100)

        // Drill into a "Tracks"/"Songs"/… category if the top level is sections.
        if let section = items.first(where: { isTrackSection($0.title) && $0.hint == "list" && $0.itemKey != nil }),
           let key = section.itemKey {
            _ = try await searchStep(itemKey: key, sessionKey: session)
            items = try await searchLoad(sessionKey: session, count: min(limit * 2, 100))
        }

        let trackItems = items.filter {
            ($0.hint == "action" || $0.hint == "action_list") && $0.itemKey != nil
        }.prefix(limit)

        return trackItems.map { item in
            let parts = (item.subtitle ?? "").split(separator: "•").map { $0.trimmingCharacters(in: .whitespaces) }
            let artist = parts.first ?? ""
            let album = parts.count > 1 ? parts[1] : nil
            let key = Self.qobuzSearchPrefix + encodeKeyPart(artist) + "::" + encodeKeyPart(item.title)
            return SearchResult(
                title: item.title,
                artist: artist.isEmpty ? nil : artist,
                album: album,
                syntheticKey: key
            )
        }
    }

    /// Fresh search at play time → navigate to the best track → execute its
    /// Play Now / Queue action. Used for synthetic Qobuz keys.
    @discardableResult
    private func playViaSearch(artist: String, title: String, zoneID: String, action: String) async throws -> Bool {
        let session = "qobuz_play_\(zoneID)"
        let query = artist.isEmpty ? title : "\(artist) \(title)"

        _ = try await searchStep(input: query, zoneID: zoneID, sessionKey: session)
        var items = try await searchLoad(sessionKey: session, count: 30)

        if let section = items.first(where: { isTrackSection($0.title) && $0.hint == "list" && $0.itemKey != nil }),
           let key = section.itemKey {
            _ = try await searchStep(itemKey: key, zoneID: zoneID, sessionKey: session)
            items = try await searchLoad(sessionKey: session, count: 20)
        }

        guard let track = items.first(where: {
            ($0.hint == "action" || $0.hint == "action_list") && $0.itemKey != nil
        }), let trackKey = track.itemKey else { return false }

        // Open the track's action menu and pick Play Now / Queue.
        let resp = try await searchStep(itemKey: trackKey, zoneID: zoneID, sessionKey: session)
        guard let list = resp["list"] as? [String: Any],
              let count = list["count"] as? Int, count > 0 else {
            // Some track rows execute directly on browse — treat as success.
            return true
        }
        let actions = try await searchLoad(sessionKey: session, count: min(count, 20))
        let targetTitle = action == "queue" ? "Queue" : (action == "add_next" ? "Add Next" : "Play Now")
        let actionItem = actions.first(where: {
            $0.hint == "action" && $0.title.localizedCaseInsensitiveContains(targetTitle)
        }) ?? actions.first(where: { $0.hint == "action" })

        guard let actionKey = actionItem?.itemKey else { return false }
        _ = try await searchStep(itemKey: actionKey, zoneID: zoneID, sessionKey: session)
        return true
    }
}
