import AppKit
import Foundation
import Observation

/// Self-updater for the analyzer app. Checks GitHub Releases for the newest
/// `analyzer-v*` release (separate lifecycle from the main RoonSage app) and
/// installs it via the same Sparkle-style detached-script handoff.
@MainActor
@Observable
final class AnalyzerUpdater {

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    struct UpdateInfo: Equatable {
        let version: String
        let dmgURL: String
    }

    var available: UpdateInfo?
    var isInstalling = false

    private let releasesURL = URL(string: "https://api.github.com/repos/Georgemvp/roon-mediasage/releases?per_page=40")!
    private let tagPrefix = "analyzer-v"

    func checkOnLaunch() async {
        available = await check()
    }

    func check() async -> UpdateInfo? {
        var req = URLRequest(url: releasesURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        var best: UpdateInfo?
        for rel in arr {
            guard let tag = rel["tag_name"] as? String, tag.hasPrefix(tagPrefix) else { continue }
            let ver = String(tag.dropFirst(tagPrefix.count))
            guard isNewer(ver, than: Self.currentVersion) else { continue }
            let assets = rel["assets"] as? [[String: Any]] ?? []
            guard let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true })?["browser_download_url"] as? String else { continue }
            if best == nil || isNewer(ver, than: best!.version) { best = UpdateInfo(version: ver, dmgURL: dmg) }
        }
        return best
    }

    func installUpdate() async {
        guard let info = available, !isInstalling else { return }
        isInstalling = true
        guard let url = URL(string: info.dmgURL),
              let (tmp, _) = try? await URLSession.shared.download(from: url) else { isInstalling = false; return }
        let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("RoonSageAnalyzer-update.dmg")
        try? FileManager.default.removeItem(at: dmg)
        do { try FileManager.default.moveItem(at: tmp, to: dmg) } catch { isInstalling = false; return }

        launchInstaller(dmgURL: dmg)
        try? await Task.sleep(nanoseconds: 600_000_000)
        NSApp.terminate(nil)
    }

    private func launchInstaller(dmgURL: URL) {
        let destApp = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let tmp = FileManager.default.temporaryDirectory
        let mountPoint = tmp.appendingPathComponent("rsanalyzer-mnt")
        let scriptURL = tmp.appendingPathComponent("rsanalyzer-install.sh")
        let appName = destApp.lastPathComponent   // "RoonSage Analyzer.app"

        let script = """
        #!/bin/bash
        DMG="\(dmgURL.path)"
        DEST="\(destApp.path)"
        MNT="\(mountPoint.path)"
        for _ in $(seq 1 30); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done
        if kill -0 \(pid) 2>/dev/null; then kill \(pid) 2>/dev/null; sleep 0.5; kill -9 \(pid) 2>/dev/null; sleep 0.3; fi
        rm -rf "$MNT"; mkdir -p "$MNT"
        xattr -dr com.apple.quarantine "$DMG" 2>/dev/null
        hdiutil attach "$DMG" -mountpoint "$MNT" -nobrowse -noautoopen -noverify -quiet || { open "$DEST"; exit 1; }
        SRC="$MNT/\(appName)"
        if [ ! -d "$SRC" ]; then hdiutil detach "$MNT" -quiet -force; open "$DEST"; exit 1; fi
        ditto "$SRC" "$DEST.new" || { hdiutil detach "$MNT" -quiet -force; open "$DEST"; exit 1; }
        hdiutil detach "$MNT" -quiet -force
        xattr -dr com.apple.quarantine "$DEST.new" 2>/dev/null
        rm -rf "$DEST.old"
        [ -d "$DEST" ] && mv "$DEST" "$DEST.old"
        mv "$DEST.new" "$DEST" || { [ -d "$DEST.old" ] && mv "$DEST.old" "$DEST"; open "$DEST"; exit 1; }
        rm -rf "$DEST.old"
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        open "$DEST"
        """
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments = ["-c", "nohup bash '\(scriptURL.path)' >/dev/null 2>&1 &"]
        try? launcher.run()
    }

    private func isNewer(_ a: String, than b: String) -> Bool {
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
