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
        sessionKey: String
    ) async throws -> [String: Any] {
        var body: [String: Any] = [
            "hierarchy": hierarchy,
            "multi_session_key": sessionKey
        ]
        if let itemKey { body["item_key"] = itemKey }
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
        hierarchy: String = "browse"
    ) async throws -> Int {
        let resp = try await browse(hierarchy: hierarchy, itemKey: itemKey, sessionKey: sessionKey)
        guard let list = resp["list"] as? [String: Any],
              let count = list["count"] as? Int else {
            throw BrowseError.noList
        }
        return count
    }

    /// Browse into `itemKey` and load ALL items, auto-paginating.
    func browseAll(
        to itemKey: String?,
        sessionKey: String,
        hierarchy: String = "browse"
    ) async throws -> [Item] {
        let total = try await navigate(to: itemKey, sessionKey: sessionKey, hierarchy: hierarchy)
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
}
