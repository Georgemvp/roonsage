import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// Manages the full lifecycle of an in-app update:
/// download DMG with progress → mount → replace .app bundle → relaunch.
@MainActor
@Observable
public final class UpdateInstaller {

    public enum State: Sendable {
        case idle
        case downloading(progress: Double)    // 0.0 – 1.0
        case readyToInstall(dmgURL: URL)
        case installing
        case error(String)
    }

    public private(set) var state: State = .idle

    private var downloadTask: URLSessionDownloadTask?
    private var progressObserver: NSKeyValueObservation?

    public init() {}

    // MARK: - Download

    public func download(from urlString: String) {
        guard let url = URL(string: urlString) else {
            state = .error("Invalid download URL.")
            return
        }
        state = .downloading(progress: 0)

        // Use the completion-handler variant so we get the temp file URL
        let task = URLSession.shared.downloadTask(with: url) { [weak self] location, _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.progressObserver = nil
                self.downloadTask = nil

                if let error {
                    // Ignore cancellation
                    if (error as NSError).code == NSURLErrorCancelled { return }
                    self.state = .error("Download failed: \(error.localizedDescription)")
                    return
                }
                guard let location else {
                    self.state = .error("Download produced no file.")
                    return
                }

                // Move from the ephemeral temp location to a stable path
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("RoonSage-update.dmg")
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.moveItem(at: location, to: dest)
                    self.state = .readyToInstall(dmgURL: dest)
                } catch {
                    self.state = .error("Could not save download: \(error.localizedDescription)")
                }
            }
        }

        // Observe download progress via KVO
        progressObserver = task.progress.observe(\.fractionCompleted, options: [.new]) {
            [weak self] progress, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .downloading = self.state {
                    self.state = .downloading(progress: progress.fractionCompleted)
                }
            }
        }

        downloadTask = task
        task.resume()
    }

    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        progressObserver = nil
        state = .idle
    }

    // MARK: - Install

    /// Mounts the DMG, replaces the running .app bundle, then relaunches.
    public func install(dmgURL: URL) async {
        state = .installing
        do {
            let newAppURL = try await performInstall(dmgURL: dmgURL)
            relaunch(newAppURL: newAppURL)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func performInstall(dmgURL: URL) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
        let mountPoint = tmp.appendingPathComponent("roonsage-update-mnt")
        let stagingApp  = tmp.appendingPathComponent("RoonSage-update.app")

        // Prepare temp dirs
        try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: mountPoint)
            try? FileManager.default.removeItem(at: stagingApp)
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        }.value

        // Strip quarantine + mount (skip Gatekeeper verification)
        _ = try? await runProcess("/usr/bin/xattr",
                                  args: ["-dr", "com.apple.quarantine", dmgURL.path])
        try await runProcess("/usr/bin/hdiutil", args: [
            "attach", dmgURL.path,
            "-mountpoint", mountPoint.path,
            "-quiet", "-nobrowse", "-noautoopen", "-noverify"
        ])

        let appInDMG = mountPoint.appendingPathComponent("RoonSage.app")
        guard FileManager.default.fileExists(atPath: appInDMG.path) else {
            _ = try? await runProcess("/usr/bin/hdiutil",
                                      args: ["detach", mountPoint.path, "-quiet", "-force"])
            throw InstallError.appNotFoundInDMG
        }

        // Copy new app to a staging location (NOT the running bundle — macOS blocks that)
        let src = appInDMG, stage = stagingApp
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: src, to: stage)
        }.value

        // Unmount DMG now that we have the app in staging
        _ = try? await runProcess("/usr/bin/hdiutil",
                                  args: ["detach", mountPoint.path, "-quiet"])

        // Strip quarantine from staging copy
        _ = try? await runProcess("/usr/bin/xattr",
                                  args: ["-dr", "com.apple.quarantine", stagingApp.path])

        // Write a shell script that replaces the bundle AFTER we quit.
        // This is the Sparkle pattern: the running binary is never locked when replaced.
        let destApp  = Bundle.main.bundleURL
        let scriptURL = tmp.appendingPathComponent("roonsage-update.sh")
        let script = """
        #!/bin/bash
        # Wait for the app process to exit
        sleep 1
        rm -rf '\(destApp.path)'
        mv '\(stagingApp.path)' '\(destApp.path)'
        xattr -dr com.apple.quarantine '\(destApp.path)' 2>/dev/null
        open '\(destApp.path)'
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try await runProcess("/bin/chmod", args: ["+x", scriptURL.path])

        // Launch the script detached (survives our process exit)
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments    = [scriptURL.path]
        try launcher.run()

        return destApp
    }

    private func relaunch(newAppURL: URL) {
        // The shell script handles the open; we just need to quit.
        #if canImport(AppKit)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
        #endif
    }

    private func runProcess(_ executable: String, args: [String], timeout: TimeInterval = 60) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: executable)
                    p.arguments = args
                    p.standardOutput = FileHandle.nullDevice
                    p.standardError  = FileHandle.nullDevice
                    p.terminationHandler = { proc in
                        if proc.terminationStatus == 0 {
                            cont.resume()
                        } else {
                            cont.resume(throwing: InstallError.processFailed(executable, proc.terminationStatus))
                        }
                    }
                    do { try p.run() } catch { cont.resume(throwing: error) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw InstallError.processFailed(executable, -1)
            }
            // First to finish wins; cancel the other
            try await group.next()!
            group.cancelAll()
        }
    }
}

// MARK: - Errors

public enum InstallError: LocalizedError {
    case appNotFoundInDMG
    case replaceFailed(Error)
    case processFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .appNotFoundInDMG:
            "RoonSage.app was not found in the downloaded update package."
        case .replaceFailed(let e):
            "Could not replace the existing app: \(e.localizedDescription)"
        case .processFailed(let cmd, let code):
            "\(URL(fileURLWithPath: cmd).lastPathComponent) failed (exit \(code))."
        }
    }
}
