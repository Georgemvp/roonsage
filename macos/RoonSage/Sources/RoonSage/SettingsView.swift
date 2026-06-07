import SwiftUI
import RoonSageCore

struct SettingsView: View {
    @Environment(RoonClient.self) private var client
    @State private var lastSync: String = "—"

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
        .onAppear { refreshLastSync() }
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
