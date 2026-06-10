import Foundation
import RoonProtocol

/// Builds the Roon extension registration payload and persists credentials.
struct RoonClientAuth {

    static let extensionInfo: [String: Any] = {
        // Each platform must have a distinct extension ID so Roon treats
        // the macOS and iOS clients as separate, independently-authorised extensions.
        #if os(iOS)
        let id   = "com.roonsage.ios"
        let name = "RoonSage iOS"
        #else
        let id   = "com.roonsage.native"
        let name = "RoonSage Native"
        #endif
        return [
            "extension_id":    id,
            "display_name":    name,
            "display_version": "2.0.0",
            "publisher":       "RoonSage",
            "email":           "hello@roonsage.app",
            "website":         "https://roonsage.app",
        ]
    }()

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
