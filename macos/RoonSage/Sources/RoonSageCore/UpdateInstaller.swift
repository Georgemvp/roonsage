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
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-update-mnt")

        try? FileManager.default.removeItem(at: mountPoint)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        // Mount the DMG
        try await runProcess("/usr/bin/hdiutil", args: [
            "attach", dmgURL.path,
            "-mountpoint", mountPoint.path,
            "-quiet", "-nobrowse", "-noautoopen"
        ])

        let appInDMG = mountPoint.appendingPathComponent("RoonSage.app")

        guard FileManager.default.fileExists(atPath: appInDMG.path) else {
            _ = try? await runProcess("/usr/bin/hdiutil",
                                      args: ["detach", mountPoint.path, "-quiet", "-force"])
            throw InstallError.appNotFoundInDMG
        }

        // Destination: same location as the currently running app
        let destApp = Bundle.main.bundleURL

        do {
            // Remove old app and copy in new one
            try? FileManager.default.removeItem(at: destApp)
            try FileManager.default.copyItem(at: appInDMG, to: destApp)
        } catch {
            _ = try? await runProcess("/usr/bin/hdiutil",
                                      args: ["detach", mountPoint.path, "-quiet", "-force"])
            throw InstallError.replaceFailed(error)
        }

        // Strip quarantine attribute from the freshly installed app
        _ = try? await runProcess("/usr/bin/xattr",
                                  args: ["-dr", "com.apple.quarantine", destApp.path])

        // Unmount DMG
        _ = try? await runProcess("/usr/bin/hdiutil",
                                  args: ["detach", mountPoint.path, "-quiet"])

        return destApp
    }

    private func relaunch(newAppURL: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(newAppURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NSApp.terminate(nil)
        }
        #endif
    }

    private func runProcess(_ executable: String, args: [String]) async throws {
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
            do {
                try p.run()
            } catch {
                cont.resume(throwing: error)
            }
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
