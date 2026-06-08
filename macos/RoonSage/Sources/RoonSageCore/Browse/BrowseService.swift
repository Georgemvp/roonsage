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

        init(from dict: [String: Any]) {
            title    = dict["title"]    as? String ?? ""
            subtitle = dict["subtitle"] as? String
            itemKey  = dict["item_key"] as? String
            hint     = dict["hint"]     as? String
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
                guard let albumsItem = contents.first(where: {
                    $0.title.lowercased() == "albums" && $0.hint == "list"
                }), let albumsKey = albumsItem.itemKey else { continue }

                let albums = try await browseAll(to: albumsKey, sessionKey: sessionKey, hierarchy: "genres")
                for album in albums {
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
}
