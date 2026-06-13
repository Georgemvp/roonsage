import Foundation
import Security

public enum KeychainStore {
    /// Per-process keychain service namespace. The always-on server build sets
    /// this to its own value so it never reads credential items created by a
    /// differently-signed sibling app (the Mac/iOS clients) — a cross-app read
    /// triggers a blocking SecurityAgent ACL prompt, which on the main thread
    /// freezes the app (it froze `RoonClient.handleOpen` reading the Roon token).
    /// Clients keep the default namespace, so their existing items stay readable.
    public static var serviceOverride: String?
    private static var service: String { serviceOverride ?? "com.roonsage.native" }

    /// Stores `value` under `key`. Returns false if the Keychain write failed
    /// (e.g. permission/disk error) so callers can surface lost-credential state
    /// instead of silently "succeeding".
    @discardableResult
    public static func save(key: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData] = data
        // Device-only, post-first-unlock: the Roon token and scrobble keys
        // must not sync via iCloud Keychain or end up in device backups,
        // and background tasks (scrobbling) may need them while locked.
        attrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        return status == errSecSuccess
    }

    public static func load(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func delete(key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
