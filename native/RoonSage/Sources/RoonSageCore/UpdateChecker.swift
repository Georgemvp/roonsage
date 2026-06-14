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

    // The repo ships three release lifecycles: macOS (`v1.2.3`), iOS
    // (`ios-v…`) and the analyzer (`analyzer-v…`). `releases/latest` returns
    // whichever was published last, so an analyzer/iOS tag would hide a real
    // macOS update (or offer a bogus one). Scan the list and keep only macOS
    // `v*` tags.
    private let releasesURL = URL(string: "https://api.github.com/repos/Georgemvp/roon-mediasage/releases?per_page=40")!

    private init() {}

    /// Returns an `UpdateInfo` for the newest macOS (`v*`) release that's newer
    /// than `currentVersion`, otherwise `nil`.
    public func checkForUpdates(currentVersion: String) async -> UpdateInfo? {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        var best: UpdateInfo?
        for rel in releases {
            guard let tag = rel["tag_name"] as? String, Self.isMacRelease(tag) else { continue }
            let version = String(tag.dropFirst())   // strip leading "v"
            guard isNewer(version, than: currentVersion) else { continue }

            let releasePageURL = rel["html_url"] as? String ?? "https://github.com/Georgemvp/roon-mediasage/releases"
            let assets = rel["assets"] as? [[String: Any]] ?? []
            let dmgURL = assets
                .first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
                .flatMap { $0["browser_download_url"] as? String }
                ?? releasePageURL

            if best == nil || isNewer(version, than: best!.version) {
                best = UpdateInfo(
                    version: version,
                    downloadURL: dmgURL,
                    releasePageURL: releasePageURL,
                    releaseNotes: rel["body"] as? String
                )
            }
        }
        return best
    }

    /// macOS releases are `v1.2.3`; `ios-v…`/`analyzer-v…` must be ignored.
    private static func isMacRelease(_ tag: String) -> Bool {
        guard tag.hasPrefix("v"), tag.count > 1 else { return false }
        return tag[tag.index(after: tag.startIndex)].isNumber
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
