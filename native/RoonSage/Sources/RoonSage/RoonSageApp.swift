import SwiftUI
import RoonSageCore
import RoonSageUI

@MainActor
@main
struct RoonSageApp: App {
    @State private var client: RoonClient
    @State private var availableUpdate: UpdateInfo? = nil
    @State private var showUpdateSheet = false
    @State private var isCheckingForUpdates = false
    @State private var installer = UpdateInstaller()

    init() {
        // This is a client: control Roon through the RoonSage server over HTTP,
        // never register a Roon extension on this Mac. Must run before connect.
        RoonClient.useServerMode()
        _client = State(initialValue: RoonClient.shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(client)
                .roonSageAppearance()
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
                Button(isCheckingForUpdates ? "Zoeken naar updates…" : "Zoek naar updates…") {
                    Task { await checkForUpdatesManually() }
                }
                .disabled(isCheckingForUpdates)
            }
            CommandMenu("Bediening") {
                Button("Speel / pauzeer") { transport { z in await client.playPause(zoneID: z) } }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Volgende track") { transport { z in await client.next(zoneID: z) } }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Vorige track") { transport { z in await client.previous(zoneID: z) } }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
                Button("Volume omhoog") { volume(+4) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Volume omlaag") { volume(-4) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(client)
                .roonSageAppearance()
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(client)
                .roonSageAppearance()
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
            alert.messageText = "Je bent up-to-date"
            alert.informativeText = "RoonSage \(currentVersion) is de nieuwste versie."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
