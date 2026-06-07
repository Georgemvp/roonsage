import SwiftUI
import RoonSageCore

@MainActor
struct SettingsView: View {
    @Environment(RoonClient.self) private var client
    @State private var lastSync: String = "—"
    @State private var lbToken: String = ""
    @State private var lbSaved = false

    var body: some View {
        Form {
            // Connection
            Section("Roon Connection") {
                LabeledContent("Status", value: client.connectionState.label)
                if let host = client.coreHost {
                    LabeledContent("Host", value: "\(host):\(client.corePort)")
                }
                HStack {
                    Button("Disconnect") {
                        Task { await client.disconnect() }
                    }
                    .disabled(!client.connectionState.isConnected)

                    Button("Re-authorize", role: .destructive) {
                        Task { await client.clearAndReauthorize() }
                    }
                    .disabled(!client.connectionState.isConnected)
                }
            }

            // Library
            Section("Library") {
                LabeledContent("Tracks in database", value: "\(client.trackCount)")
                LabeledContent("Last sync", value: lastSync)
                HStack {
                    Button("Sync Now") { client.startSync() }
                        .disabled(!client.connectionState.isConnected || client.isSyncing)
                    if client.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                        Text(client.syncProgress.phase)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // External Services
            Section("External Services") {
                LabeledContent("ListenBrainz token") {
                    HStack(spacing: 8) {
                        SecureField("Paste token here", text: $lbToken)
                            .textFieldStyle(.roundedBorder)
                        Button(lbSaved ? "Saved!" : "Save") {
                            if lbToken.trimmingCharacters(in: .whitespaces).isEmpty {
                                KeychainStore.delete(key: "listenbrainz_token")
                            } else {
                                KeychainStore.save(key: "listenbrainz_token", value: lbToken.trimmingCharacters(in: .whitespaces))
                            }
                            lbSaved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { lbSaved = false }
                        }
                    }
                }
                Text("Scrobbles each track to ListenBrainz as it starts playing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // About
            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Protocol", value: "MOO/1 · SOOD · GRDB 6")
                LabeledContent("Platform", value: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(width: 440)
        .onAppear {
            refreshLastSync()
            lbToken = KeychainStore.load(key: "listenbrainz_token") ?? ""
        }
        .onChange(of: client.isSyncing) { _, _ in refreshLastSync() }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (build \(b))"
    }

    private func refreshLastSync() {
        lastSync = (try? client.database?.syncStateValue(forKey: "last_sync")) ?? "Never"
    }
}
