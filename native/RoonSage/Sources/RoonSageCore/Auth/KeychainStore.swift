import Foundation
import Security

public enum KeychainStore {
    private static let service = "com.roonsage.native"

    /// Keychain access group (team-prefixed) used by the always-on server
    /// (analyzer) build, which declares it in its `keychain-access-groups`
    /// entitlement. Scoping the server's queries to this group stops macOS from
    /// popping a blocking ACL prompt when it encounters credential items created
    /// by a differently-signed sibling app on the same machine. The client apps
    /// (Mac/iOS) and all unsigned/dev builds have no such entitlement — every
    /// call transparently falls back to a group-less query that uses each app's
    /// own default group (see `missingEntitlement`).
    private static let accessGroup = "5W3QDZ94FH.com.roonsage.shared"

    /// errSecMissingEntitlement (-34018): the binary isn't signed with the
    /// access group. Returned on unsigned/ad-hoc/dev builds.
    private static func missingEntitlement(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement
    }

    private static func baseQuery(_ key: String, group: Bool) -> [CFString: Any] {
        var q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        if group { q[kSecAttrAccessGroup] = accessGroup }
        return q
    }

    /// Stores `value` under `key`. Returns false if the Keychain write failed
    /// (e.g. permission/disk error) so callers can surface lost-credential state
    /// instead of silently "succeeding".
    @discardableResult
    public static func save(key: String, value: String) -> Bool {
        let data = Data(value.utf8)
        func write(group: Bool) -> OSStatus {
            let query = baseQuery(key, group: group)
            SecItemDelete(query as CFDictionary)
            var attrs = query
            attrs[kSecValueData] = data
            // Device-only, post-first-unlock: the Roon token and scrobble keys
            // must not sync via iCloud Keychain or end up in device backups,
            // and background tasks (scrobbling) may need them while locked.
            attrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(attrs as CFDictionary, nil)
        }
        var status = write(group: true)
        if missingEntitlement(status) { status = write(group: false) }
        return status == errSecSuccess
    }

    public static func load(key: String) -> String? {
        func read(group: Bool) -> (OSStatus, Data?) {
            var query = baseQuery(key, group: group)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }
        var (status, data) = read(group: true)
        if missingEntitlement(status) { (status, data) = read(group: false) }
        guard status == errSecSuccess, let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func delete(key: String) -> Bool {
        func remove(group: Bool) -> OSStatus {
            SecItemDelete(baseQuery(key, group: group) as CFDictionary)
        }
        var status = remove(group: true)
        if missingEntitlement(status) { status = remove(group: false) }
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
