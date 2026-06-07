import SwiftUI
import RoonSageCore

/// Shown when the app is not connected to a Roon Core.
/// Supports auto-discovery and manual IP entry.
@MainActor
struct ConnectView: View {
    @Environment(RoonClient.self) private var client
    @State private var host = ""
    @State private var port = "9330"
    @State private var showManual = false

    var isWorking: Bool {
        switch client.connectionState {
        case .discovering, .connecting, .awaitingAuthorization: true
        default: false
        }
    }

    var isFailed: Bool {
        if case .failed = client.connectionState { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Logo / header
            VStack(spacing: 12) {
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.accentColor)
                Text("RoonSage")
                    .font(.largeTitle.bold())
                Text("Native macOS Client")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            // Status
            if isWorking || isFailed {
                statusBanner
            }

            // Action buttons
            VStack(spacing: 12) {
                Button(action: { Task { await client.discoverAndConnect() } }) {
                    Label("Discover Roon Core", systemImage: "magnifyingglass")
                        .frame(minWidth: 240)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking)

                Button("Enter IP address manually") {
                    withAnimation { showManual.toggle() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            // Manual entry
            if showManual {
                manualEntry
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Spacer()

            // Help text
            Text("Make sure Roon is running on the same network.\nAfter connecting, open Roon → Settings → Extensions and enable RoonSage.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var statusBanner: some View {
        HStack(spacing: 10) {
            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Text(client.connectionState.label)
                .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    var manualEntry: some View {
        HStack(spacing: 8) {
            TextField("Roon Core IP", text: $host)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            TextField("Port", text: $port)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            Button("Connect") {
                guard let p = UInt16(port), !host.isEmpty else { return }
                Task { await client.connect(host: host, port: p) }
            }
            .disabled(host.isEmpty || isWorking)
        }
    }
}
