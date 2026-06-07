import Foundation

public struct UpdateInfo: Sendable {
    public let version: String
    public let downloadURL: String
    public let releasePageURL: String
    public let releaseNotes: String?
}

/// Checks GitHub Releases for a newer version of RoonSage.
/// Uses the public GitHub API — no auth token required.
public actor UpdateChecker {

    public static let shared = UpdateChecker()

    private let apiURL = URL(string: "https://api.github.com/repos/Georgemvp/roon-mediasage/releases/latest")!

    private init() {}

    /// Returns an `UpdateInfo` if a newer version is available, otherwise `nil`.
    public func checkForUpdates(currentVersion: String) async -> UpdateInfo? {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let tagName = json["tag_name"] as? String else { return nil }
        let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

        // Compare using version components so "1.0.1" > "1.0.0"
        guard isNewer(latestVersion, than: currentVersion) else { return nil }

        let releasePageURL = json["html_url"] as? String ?? "https://github.com/Georgemvp/roon-mediasage/releases"
        let releaseNotes   = json["body"] as? String

        // Find the DMG asset
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmgURL = assets
            .first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
            .flatMap { $0["browser_download_url"] as? String }
            ?? releasePageURL

        return UpdateInfo(
            version: latestVersion,
            downloadURL: dmgURL,
            releasePageURL: releasePageURL,
            releaseNotes: releaseNotes
        )
    }

    // MARK: - Version comparison

    private func isNewer(_ latest: String, than current: String) -> Bool {
        let lParts = latest.split(separator: ".").compactMap { Int($0) }
        let cParts = current.split(separator: ".").compactMap { Int($0) }
        let count = max(lParts.count, cParts.count)
        for i in 0..<count {
            let l = i < lParts.count ? lParts[i] : 0
            let c = i < cParts.count ? cParts[i] : 0
            if l != c { return l > c }
        }
        return false
    }
}
