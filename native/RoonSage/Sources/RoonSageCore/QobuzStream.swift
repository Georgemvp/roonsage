import CryptoKit
import Foundation

/// Request signing for Qobuz's `track/getFileUrl` streaming endpoint.
///
/// EXPERIMENTAL / UNOFFICIAL: Qobuz exposes no public streaming API. This
/// mirrors the long-standing community scheme (qobuz-dl / streamrip): the
/// request is signed with the web-player `app_secret`, which Qobuz rotates and
/// whose use isn't endorsed. It needs a valid Qobuz **subscription**; it's
/// off by default and clearly labelled in Settings. Failures degrade to the
/// normal "not playable locally" filter, so a wrong/expired secret never breaks
/// the rest of local playback.
public enum QobuzStream {
    /// The exact string that gets MD5'd, minus the trailing secret. Qobuz builds
    /// it as `object + method + (params sorted by key, "key"+"value")  + ts`.
    /// For getFileUrl the signed params are format_id, intent, track_id (already
    /// alphabetical). Exposed so the assembly order is unit-tested without MD5.
    public static func signatureBase(formatID: Int, intent: String, trackID: Int, timestamp: Int) -> String {
        "trackgetFileUrl"
            + "format_id\(formatID)"
            + "intent\(intent)"
            + "track_id\(trackID)"
            + "\(timestamp)"
    }

    /// `request_sig` = md5(signatureBase + app_secret).
    public static func requestSignature(formatID: Int, intent: String, trackID: Int,
                                        timestamp: Int, appSecret: String) -> String {
        md5Hex(signatureBase(formatID: formatID, intent: intent, trackID: trackID, timestamp: timestamp) + appSecret)
    }

    /// Lowercase hex MD5 of a UTF-8 string.
    public static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
