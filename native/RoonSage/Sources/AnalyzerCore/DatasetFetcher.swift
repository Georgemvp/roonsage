import Foundation

/// Fetches the pre-distilled MusicMoveArr sidecar (`metadata.db`, built offline by
/// `native/scripts/distill-datasets.sh`) from a GitHub Release asset — lets a NEW
/// RoonSage install skip the multi-hour torrent download + DuckDB distillation
/// that produced it. Mirrors `AnalyzerUpdater`'s GitHub-Releases lookup (same
/// repo, separate tag namespace: `dataset-vN`, asset name `metadata.db.gz`).
public enum DatasetFetcher {
    public struct Release: Sendable, Equatable {
        public let version: String
        public let downloadURL: String
    }

    public enum FetchError: Error, CustomStringConvertible {
        case downloadFailed
        case decompressFailed(String)

        public var description: String {
            switch self {
            case .downloadFailed: return "download failed"
            case .decompressFailed(let m): return "decompress failed: \(m)"
            }
        }
    }

    static let releasesURL = URL(string: "https://api.github.com/repos/Georgemvp/roonsage/releases?per_page=40")!
    static let tagPrefix = "dataset-v"
    static let assetSuffix = ".db.gz"

    /// Pure parse of the GitHub Releases API response — the newest `dataset-vN`
    /// release carrying a `.db.gz` asset. Separated from the network call so it's
    /// unit-testable against a fixture payload, like the rest of the importer.
    public static func newestRelease(fromReleasesJSON data: Data) -> Release? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var best: Release?
        for rel in arr {
            guard let tag = rel["tag_name"] as? String, tag.hasPrefix(tagPrefix) else { continue }
            let version = String(tag.dropFirst(tagPrefix.count))
            let assets = rel["assets"] as? [[String: Any]] ?? []
            guard let url = assets.first(where: { ($0["name"] as? String)?.hasSuffix(assetSuffix) == true })?["browser_download_url"] as? String
            else { continue }
            if best == nil || isNewer(version, than: best!.version) { best = Release(version: version, downloadURL: url) }
        }
        return best
    }

    /// Query GitHub for the newest `dataset-vN` release. nil on any network/parse
    /// failure — callers treat that like "nothing to offer", not a hard error.
    public static func fetchLatestRelease() async -> Release? {
        var req = URLRequest(url: releasesURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return newestRelease(fromReleasesJSON: data)
    }

    /// Downloads the `.db.gz` asset and gunzips it to `destPath` (overwritten if
    /// present). Shells out to the system `gunzip` — present on every Mac, and
    /// this app already trusts a system binary the same way for update installs
    /// (`hdiutil`/`ditto` in `AnalyzerUpdater`). Blocking; call from a background
    /// task, not the main actor.
    public static func download(_ release: Release, to destPath: String) async throws {
        guard let url = URL(string: release.downloadURL),
              let (tmp, resp) = try? await URLSession.shared.download(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.downloadFailed }
        let gz = FileManager.default.temporaryDirectory.appendingPathComponent("roonsage-dataset-\(UUID().uuidString).db.gz")
        try? FileManager.default.removeItem(at: gz)
        try FileManager.default.moveItem(at: tmp, to: gz)
        defer { try? FileManager.default.removeItem(at: gz) }

        try? FileManager.default.removeItem(atPath: destPath)
        guard FileManager.default.createFile(atPath: destPath, contents: nil) else {
            throw FetchError.decompressFailed("could not create \(destPath)")
        }
        guard let handle = FileHandle(forWritingAtPath: destPath) else {
            throw FetchError.decompressFailed("could not open \(destPath) for writing")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        proc.arguments = ["-k", "-c", gz.path]   // -c: decompressed bytes to stdout, -k: keep the .gz
        proc.standardOutput = handle
        try proc.run()
        proc.waitUntilExit()
        try? handle.close()
        guard proc.terminationStatus == 0 else {
            throw FetchError.decompressFailed("gunzip exited \(proc.terminationStatus)")
        }
    }

    /// Where a fetched sidecar lands by default — alongside analyzer.db, so it
    /// survives app updates and is easy to find for a manual `dataset_sidecar_path`.
    public static func defaultSidecarPath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RoonSageAnalyzer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dataset-metadata.db").path
    }

    private static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
