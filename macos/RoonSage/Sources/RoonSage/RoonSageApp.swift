import SwiftUI
import RoonSageCore

@MainActor
@main
struct RoonSageApp: App {
    @State private var client = RoonClient()
    @State private var availableUpdate: UpdateInfo? = nil
    @State private var showUpdateSheet = false
    @State private var isCheckingForUpdates = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(client)
                .frame(minWidth: 900, minHeight: 600)
                .sheet(isPresented: $showUpdateSheet) {
                    if let update = availableUpdate {
                        UpdateView(update: update)
                    }
                }
                .task { await checkForUpdatesOnLaunch() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()
                Button(isCheckingForUpdates ? "Checking for Updates…" : "Check for Updates…") {
                    Task { await checkForUpdatesManually() }
                }
                .disabled(isCheckingForUpdates)
            }
        }

        Settings {
            SettingsView()
                .environment(client)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(client)
        } label: {
            Image(systemName: "music.note.house")
        }
        .menuBarExtraStyle(.window)
    }

    // MARK: - Update checks

    /// Silently checks once per day on launch — shows sheet only if update found.
    private func checkForUpdatesOnLaunch() async {
        // Throttle: check at most once per 24h
        let lastCheckKey = "lastUpdateCheck"
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard now - last > 86400 else { return }
        UserDefaults.standard.set(now, forKey: lastCheckKey)

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        if let update = await UpdateChecker.shared.checkForUpdates(currentVersion: currentVersion) {
            availableUpdate = update
            showUpdateSheet = true
        }
    }

    /// Called from "Check for Updates…" menu item — always shows result.
    private func checkForUpdatesManually() async {
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        if let update = await UpdateChecker.shared.checkForUpdates(currentVersion: currentVersion) {
            availableUpdate = update
            showUpdateSheet = true
        } else {
            // Show "up to date" alert
            let alert = NSAlert()
            alert.messageText = "You're up to date"
            alert.informativeText = "RoonSage \(currentVersion) is the latest version."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
