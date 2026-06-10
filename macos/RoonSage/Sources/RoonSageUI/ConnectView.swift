import SwiftUI
import RoonSageCore

/// Shown when the app is not connected to a Roon Core.
/// On launch: tries the last-used host first (works over ZeroTier/VPN).
/// Falls back to SOOD discovery or manual IP entry.
@MainActor
public struct ConnectView: View {
    public init() {}
    @Environment(RoonClient.self) private var client
    @State private var host       = ""
    @State private var port       = "9330"
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

    public var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // Logo
            VStack(spacing: 12) {
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.roonGold)
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

            // Buttons
            VStack(spacing: 12) {

                // Reconnect to last host (shown when a host is known)
                if let saved = client.savedHost {
                    Button {
                        Task { await client.connect(host: saved, port: client.savedPort) }
                    } label: {
                        Label("Reconnect to \(saved)", systemImage: "arrow.clockwise")
                            .frame(minWidth: 240)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isWorking)
                }

                // Discover on LAN (SOOD — only works on same network)
                if client.savedHost == nil {
                    Button { Task { await client.discoverAndConnect() } } label: {
                        Label("Discover Roon Core", systemImage: "magnifyingglass").frame(minWidth: 240)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isWorking)
                } else {
                    Button { Task { await client.discoverAndConnect() } } label: {
                        Label("Discover on local network", systemImage: "magnifyingglass").frame(minWidth: 240)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isWorking)
                }

                // Manual entry toggle
                Button("Enter IP address manually") {
                    withAnimation { showManual.toggle() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            // Manual entry form
            if showManual {
                manualEntry
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Spacer()

            // Help
            Group {
                if let saved = client.savedHost {
                    Text("Remote? Use \u{201C}Reconnect to \(saved)\u{201D} — works over ZeroTier/VPN.\nOn the same network? Use \u{201C}Discover on local network\u{201D} instead.")
                } else {
                    Text("Make sure Roon is running on the same network.\nAfter connecting, open Roon → Settings → Extensions and enable RoonSage.")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.bottom, 24)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await autoConnect() }
    }

    // MARK: - Sub-views

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
                let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
                let p = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines))
                guard let p, !h.isEmpty else { return }
                Task { await client.connect(host: h, port: p) }
            }
            .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
        }
    }

    // MARK: - Auto-connect

    /// On first appearance, try the saved host silently (works over ZeroTier).
    /// If there's no saved host, do nothing — let the user click Discover.
    private func autoConnect() async {
        guard let saved = client.savedHost,
              case .disconnected = client.connectionState
        else { return }
        host = saved
        port = String(client.savedPort)
        await client.connect(host: saved, port: client.savedPort)
    }
}
