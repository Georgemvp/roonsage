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
    /// Keep retrying the saved host until connected (every ~10 s). Covers the
    /// common iOS case where the first attempt fails because ZeroTier isn't
    /// back yet after a resume — without this, a failed attempt is a dead end
    /// until the user taps Reconnect.
    @AppStorage("autoConnectEnabled") private var autoConnectEnabled = true
    @State private var retryCountdown: Int? = nil

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

    /// In server mode the app talks to the RoonSage server (not Roon directly),
    /// so the connect copy targets the server.
    var isServerMode: Bool { client.controlMode == .server }
    var discoverLabel: String { isServerMode ? "Zoek RoonSage-server" : "Zoek Roon Core" }

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
                #if os(macOS)
                Text("Native macOS-client")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                #else
                Text("Native iOS-client")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                #endif
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
                        Label("Opnieuw verbinden met \(saved)", systemImage: "arrow.clockwise")
                            .frame(minWidth: 240)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isWorking)
                }

                // Discover on LAN (SOOD — only works on same network)
                if client.savedHost == nil {
                    Button { Task { await client.discoverAndConnect() } } label: {
                        Label(discoverLabel, systemImage: "magnifyingglass").frame(minWidth: 240)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isWorking)
                } else {
                    Button { Task { await client.discoverAndConnect() } } label: {
                        Label(isServerMode ? discoverLabel : "Zoek op lokaal netwerk", systemImage: "magnifyingglass").frame(minWidth: 240)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isWorking)
                }

                // Manual entry toggle
                Button("Voer IP-adres handmatig in") {
                    withAnimation { showManual.toggle() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                // Auto-connect: keep retrying the saved host until it works.
                if client.savedHost != nil {
                    Toggle(isOn: $autoConnectEnabled) {
                        HStack(spacing: 6) {
                            Text("Automatisch verbinden")
                            if let s = retryCountdown, !isWorking {
                                Text("(opnieuw over \(s)s)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .font(.callout)
                    }
                    .toggleStyle(.switch)
                    .fixedSize()
                }
            }

            // Manual entry form
            if showManual {
                manualEntry
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Spacer()

            // Help
            Group {
                if isServerMode {
                    Text("Deze app bedient Roon via de RoonSage-server (de analyzer op je always-on Mac). Zorg dat die draait; afspelen en bediening lopen erdoorheen.")
                } else if let saved = client.savedHost {
                    Text("Op afstand? Gebruik \u{201C}Opnieuw verbinden met \(saved)\u{201D} — werkt via ZeroTier/VPN.\nOp hetzelfde netwerk? Gebruik dan \u{201C}Zoek op lokaal netwerk\u{201D}.")
                } else {
                    Text("Zorg dat Roon op hetzelfde netwerk draait.\nOpen na het verbinden Roon → Settings → Extensions en schakel RoonSage in.")
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
        // Re-arms on every state change: a failed/dropped attempt schedules the
        // next one ~10 s later, for as long as this view is on screen and the
        // toggle is on. Connecting/connected states cancel the countdown.
        .task(id: "\(autoConnectEnabled)|\(client.connectionState.label)") {
            await autoRetryLoop()
        }
    }

    // MARK: - Sub-views

    var statusBanner: some View {
        HStack(spacing: 10) {
            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.roonDanger)
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
            TextField(isServerMode ? "Server-IP" : "Roon Core IP", text: $host)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            TextField("Poort", text: $port)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            Button("Verbind") {
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

    /// While disconnected/failed with a known host: count down ~10 s, then try
    /// again. The `.task(id:)` it runs under is cancelled and restarted on
    /// every connection-state change, so a successful attempt kills the loop
    /// and a failed one schedules the next.
    private func autoRetryLoop() async {
        defer { retryCountdown = nil }
        guard autoConnectEnabled, let saved = client.savedHost else { return }
        switch client.connectionState {
        case .disconnected, .failed: break
        default: return
        }
        for remaining in stride(from: 10, through: 1, by: -1) {
            retryCountdown = remaining
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
        }
        retryCountdown = nil
        await client.connect(host: saved, port: client.savedPort)
    }
}
