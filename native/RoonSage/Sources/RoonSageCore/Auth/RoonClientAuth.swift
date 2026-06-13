import Foundation
import RoonProtocol

/// Builds the Roon extension registration payload and persists credentials.
struct RoonClientAuth {

    /// Override the registered extension identity at runtime. The analyzer/server
    /// build sets this (e.g. "com.roonsage.server") BEFORE connecting so Roon
    /// treats it as a distinct extension and it doesn't kick the Mac/iOS client
    /// apps (which keep their default per-platform IDs). Must be set before the
    /// first `connect()`. `nil` = default per-platform behaviour.
    public static var extensionIDOverride: String?
    public static var displayNameOverride: String?

    static var extensionInfo: [String: Any] {
        // Each platform/role must have a distinct extension ID so Roon treats
        // the macOS, iOS and server extensions as separate, independently-
        // authorised extensions.
        #if os(iOS)
        let defaultID   = "com.roonsage.ios"
        let defaultName = "RoonSage iOS"
        #else
        let defaultID   = "com.roonsage.native"
        let defaultName = "RoonSage Native"
        #endif
        return [
            "extension_id":    extensionIDOverride ?? defaultID,
            "display_name":    displayNameOverride ?? defaultName,
            "display_version": "2.0.0",
            "publisher":       "RoonSage",
            "email":           "hello@roonsage.app",
            "website":         "https://roonsage.app",
        ]
    }

    /// Registration payload sent to com.roonlabs.registry:1/register.
    static func registerPayload(existingToken: String?) -> [String: Any] {
        var info = extensionInfo
        info["required_services"] = [RoonService.transport, RoonService.browse]
        info["provided_services"] = [RoonService.volumeControl]
        if let token = existingToken {
            info["token"] = token
        }
        return info
    }

    /// Parse the body returned in the "Registered" frame.
    static func parseRegistration(_ body: [String: Any]) -> (token: String, coreID: String, coreName: String)? {
        guard let token    = body["token"]        as? String,
              let coreID   = body["core_id"]      as? String,
              let coreName = body["display_name"] as? String
        else { return nil }
        return (token, coreID, coreName)
    }

    // MARK: - Persistence

    static func saveToken(_ token: String, coreID: String) {
        KeychainStore.save(key: "roon-token", value: token)
        UserDefaults.standard.set(coreID, forKey: "roon-core-id")
    }

    static func loadToken() -> String? {
        KeychainStore.load(key: "roon-token")
    }

    static func loadCoreID() -> String? {
        UserDefaults.standard.string(forKey: "roon-core-id")
    }

    static func clearCredentials() {
        KeychainStore.delete(key: "roon-token")
        UserDefaults.standard.removeObject(forKey: "roon-core-id")
    }
}
