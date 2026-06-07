import Foundation
import Observation
import RoonProtocol

/// Top-level observable client. Drives UI state and owns the transport actor.
///
/// All mutations happen on the MainActor so SwiftUI observations are safe.
/// The transport actor handles WebSocket I/O on its own executor.
@MainActor
@Observable
public final class RoonClient {

    // MARK: - State

    public enum ConnectionState: Equatable {
        case disconnected
        case discovering
        case connecting(host: String)
        case awaitingAuthorization
        case connected(coreName: String)
        case failed(String)

        public var label: String {
            switch self {
            case .disconnected:              "Disconnected"
            case .discovering:               "Searching for Roon Core…"
            case .connecting(let host):      "Connecting to \(host)…"
            case .awaitingAuthorization:     "Waiting for authorization in Roon…"
            case .connected(let name):       "Connected to \(name)"
            case .failed(let msg):           "Error: \(msg)"
            }
        }

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var zones: [Zone] = []

    // MARK: - Private

    private let transport = RoonTransport()
    private var zoneMap: [String: Zone] = [:]

    public init() {}

    // MARK: - Public API

    /// Connect to a known Roon Core host.
    public func connect(host: String, port: UInt16 = 9330) async {
        connectionState = .connecting(host: host)
        await transport.configure(
            onOpen: { [weak self] in await self?.handleOpen(host: host) },
            onClose: { [weak self] in await self?.handleClose() }
        )
        await transport.connect(host: host, port: port)
    }

    /// Auto-discover a Roon Core on the LAN, then connect.
    /// Filters to `preferredCoreID` if provided (uses the stored core_id).
    public func discoverAndConnect() async {
        connectionState = .discovering
        let preferredID = RoonClientAuth.loadCoreID()
        let cores = await SoodDiscovery.discover(coreID: preferredID)
        guard let first = cores.first else {
            connectionState = .failed("No Roon Core found on the local network.\nMake sure Roon is running.")
            return
        }
        await connect(host: first.host, port: first.httpPort)
    }

    public func disconnect() async {
        await transport.disconnect()
        connectionState = .disconnected
        zones = []
        zoneMap = [:]
    }

    public func clearAndReauthorize() async {
        RoonClientAuth.clearCredentials()
        await disconnect()
    }

    // MARK: - Private connection flow

    private func handleOpen(host: String) async {
        let token = RoonClientAuth.loadToken()
        let payload = RoonClientAuth.registerPayload(existingToken: token)

        if token == nil {
            connectionState = .awaitingAuthorization
        }

        do {
            let body = try await transport.register(payload: payload)
            guard let reg = RoonClientAuth.parseRegistration(body) else {
                connectionState = .failed("Unexpected registration response")
                return
            }
            RoonClientAuth.saveToken(reg.token, coreID: reg.coreID)
            connectionState = .connected(coreName: reg.coreName)
            await subscribeZones()
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    private func handleClose() async {
        connectionState = .disconnected
        zones = []
        zoneMap = [:]
    }

    private func subscribeZones() async {
        guard let stream = try? await transport.subscribe(
            service: RoonService.transport,
            endpoint: "zones"
        ) else { return }

        Task {
            for await body in stream {
                await self.applyZoneUpdate(body)
            }
        }
    }

    private func applyZoneUpdate(_ body: [String: Any]) async {
        let toUpdate = (body["zones_changed"] as? [[String: Any]])
            ?? (body["zones_added"]   as? [[String: Any]])
            ?? (body["zones"]         as? [[String: Any]]) ?? []
        let toRemove = body["zones_removed"] as? [String] ?? []

        for dict in toUpdate {
            let zone = Zone(from: dict)
            zoneMap[zone.id] = zone
        }
        for id in toRemove {
            zoneMap.removeValue(forKey: id)
        }
        zones = Array(zoneMap.values).sorted { $0.displayName < $1.displayName }
    }
}
