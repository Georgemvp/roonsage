import SwiftUI
import RoonSageCore

struct SettingsView: View {
    @Environment(RoonClient.self) private var client

    var body: some View {
        Form {
            Section("Roon Connection") {
                LabeledContent("Status", value: client.connectionState.label)
                Button("Disconnect") { Task { await client.disconnect() } }
                    .disabled(!client.connectionState.isConnected)
                Button("Re-authorize (clear token)", role: .destructive) {
                    Task { await client.clearAndReauthorize() }
                }
            }
            Section("About") {
                LabeledContent("Version", value: "2.0.0 (native)")
                LabeledContent("Protocol", value: "MOO/1 + SOOD")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(width: 420)
    }
}
