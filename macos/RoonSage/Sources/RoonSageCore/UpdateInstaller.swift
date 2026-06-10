import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

// The in-app DMG updater is macOS-only (Process + hdiutil + bundle swap).
// On iOS, updates ship through the App Store, so this whole subsystem is omitted.
#if os(macOS)

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

    /// Writes a self-contained installer script, launches it detached, then
    /// quits so the script can mount the DMG and replace the (now-unlocked) app
    /// bundle. ALL heavy lifting happens in the script AFTER we exit — the app
    /// never blocks on "Installing…", the swap is non-destructive (the old app
    /// is only removed once the new one is in place), and every step is logged
    /// to ~/Library/Logs/RoonSage/update.log for diagnosis.
    public func install(dmgURL: URL) async {
        state = .installing
        do {
            try launchInstallerScript(dmgURL: dmgURL)
        } catch {
            state = .error(error.localizedDescription)
            return
        }
        // Give the detached script a beat to start, then quit so it can swap us.
        try? await Task.sleep(nanoseconds: 600_000_000)
        #if canImport(AppKit)
        NSApp.terminate(nil)
        #endif
    }

    // MARK: - Private

    /// Persistent update log path (created if missing). Surfaced so the UI/user
    /// can find it after a failed update.
    public static var updateLogPath: String {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let dir = base.appendingPathComponent("Logs/RoonSage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("update.log").path
    }

    private func launchInstallerScript(dmgURL: URL) throws {
        let destApp = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let tmp = FileManager.default.temporaryDirectory
        let mountPoint = tmp.appendingPathComponent("roonsage-update-mnt")
        let scriptURL  = tmp.appendingPathComponent("roonsage-install.sh")
        let logPath = Self.updateLogPath

        // Every path is double-quoted in the script, so spaces are safe.
        let script = """
        #!/bin/bash
        LOG="\(logPath)"
        exec >>"$LOG" 2>&1
        echo "===== RoonSage update $(date) ====="
        DMG="\(dmgURL.path)"
        DEST="\(destApp.path)"
        MNT="\(mountPoint.path)"

        echo "Waiting for app (pid \(pid)) to quit…"
        for _ in $(seq 1 30); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done
        if kill -0 \(pid) 2>/dev/null; then
            echo "Still running after grace period — force-terminating so the swap + relaunch can complete"
            kill \(pid) 2>/dev/null
            for _ in $(seq 1 20); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done
            kill -9 \(pid) 2>/dev/null
            sleep 0.3
        fi

        rm -rf "$MNT"; mkdir -p "$MNT"
        xattr -dr com.apple.quarantine "$DMG" 2>/dev/null
        echo "Mounting $DMG"
        if ! hdiutil attach "$DMG" -mountpoint "$MNT" -nobrowse -noautoopen -noverify -quiet; then
            echo "ERROR: mount failed"; open "$DEST"; exit 1
        fi

        SRC="$MNT/RoonSage.app"
        if [ ! -d "$SRC" ]; then
            echo "ERROR: RoonSage.app not found in DMG"
            hdiutil detach "$MNT" -quiet -force; open "$DEST"; exit 1
        fi

        # --- Code-signature verification (anti-tamper for the downloaded app) ---
        # If the currently-installed app is signed with a Team ID, require the
        # downloaded app to (a) pass codesign verification and (b) carry the SAME
        # Team ID. This blocks a MITM'd/forged DMG from replacing a signed install.
        # Unsigned dev builds (no current Team ID) skip the check so updates keep
        # working locally.
        EXPECTED_TEAM=$(codesign -dvv "$DEST" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')
        if [ -n "$EXPECTED_TEAM" ] && [ "$EXPECTED_TEAM" != "not set" ]; then
            echo "Verifying code signature (expected team: $EXPECTED_TEAM)"
            if ! codesign --verify --deep --strict "$SRC" 2>>"$LOG"; then
                echo "ERROR: downloaded app failed code signature verification — aborting"
                hdiutil detach "$MNT" -quiet -force; open "$DEST"; exit 1
            fi
            NEW_TEAM=$(codesign -dvv "$SRC" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')
            if [ "$NEW_TEAM" != "$EXPECTED_TEAM" ]; then
                echo "ERROR: signature team mismatch ($NEW_TEAM != $EXPECTED_TEAM) — aborting"
                hdiutil detach "$MNT" -quiet -force; open "$DEST"; exit 1
            fi
        else
            echo "WARN: current app is unsigned — skipping signature check (dev build)"
        fi

        echo "Copying new app to staging ($DEST.new)"
        if ! ditto "$SRC" "$DEST.new"; then
            echo "ERROR: copy failed"
            hdiutil detach "$MNT" -quiet -force; open "$DEST"; exit 1
        fi
        hdiutil detach "$MNT" -quiet -force
        xattr -dr com.apple.quarantine "$DEST.new" 2>/dev/null

        echo "Swapping bundle (non-destructive)"
        rm -rf "$DEST.old"
        [ -d "$DEST" ] && mv "$DEST" "$DEST.old"
        if ! mv "$DEST.new" "$DEST"; then
            echo "ERROR: swap failed — restoring previous app"
            [ -d "$DEST.old" ] && mv "$DEST.old" "$DEST"
            open "$DEST"; exit 1
        fi
        rm -rf "$DEST.old"
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null

        echo "Relaunching $DEST"
        open "$DEST" || echo "ERROR: open failed"
        echo "Done."
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        // Launch fully detached via nohup, passing the script path as a real
        // argument (NOT through `bash -c "...path..."`), so no shell metacharacter
        // in the path can be interpreted. nohup keeps it alive past our exit.
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        launcher.arguments = ["/bin/bash", scriptURL.path]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        try launcher.run()
    }
}


#endif
