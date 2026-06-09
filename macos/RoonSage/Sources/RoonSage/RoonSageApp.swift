import SwiftUI
import RoonSageCore

@MainActor
@main
struct RoonSageApp: App {
    @State private var client = RoonClient()
    @State private var availableUpdate: UpdateInfo? = nil
    @State private var showUpdateSheet = false
    @State private var isCheckingForUpdates = false
    @State private var installer = UpdateInstaller()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(client)
                .frame(minWidth: 900, minHeight: 600)
                .sheet(isPresented: $showUpdateSheet) {
                    if let update = availableUpdate {
                        UpdateView(update: update, installer: installer)
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
            CommandMenu("Controls") {
                Button("Play / Pause") { transport { z in await client.playPause(zoneID: z) } }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Next Track") { transport { z in await client.next(zoneID: z) } }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Previous Track") { transport { z in await client.previous(zoneID: z) } }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
                Button("Volume Up") { volume(+4) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Volume Down") { volume(-4) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
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

    // MARK: - Transport shortcuts

    private func transport(_ action: @escaping (String) async -> Void) {
        guard let zone = client.selectedZone?.id else { return }
        Task { await action(zone) }
    }

    private func volume(_ delta: Int) {
        guard let output = client.selectedZone?.outputs.first?.id else { return }
        Task { await client.adjustVolume(outputID: output, delta: delta) }
    }

    // MARK: - Update checks

    private func checkForUpdatesOnLaunch() async {
        let lastCheckKey = "lastUpdateCheck"
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard now - last > 86400 else { return }
        UserDefaults.standard.set(now, forKey: lastCheckKey)

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        if let update = await UpdateChecker.shared.checkForUpdates(currentVersion: currentVersion) {
            availableUpdate = update
            installer = UpdateInstaller()  // fresh installer for each update
            showUpdateSheet = true
        }
    }

    private func checkForUpdatesManually() async {
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        if let update = await UpdateChecker.shared.checkForUpdates(currentVersion: currentVersion) {
            availableUpdate = update
            installer = UpdateInstaller()
            showUpdateSheet = true
        } else {
            let alert = NSAlert()
            alert.messageText = "You're up to date"
            alert.informativeText = "RoonSage \(currentVersion) is the latest version."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
