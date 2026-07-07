import Foundation

/// The one transport capability `TransportService` needs: fire a fire-and-forget
/// request frame (Roon's COMPLETE reply carries no result we wait on). Extracting
/// it as a protocol lets the service be driven by a mock in tests instead of a
/// live WebSocket — the command-building logic (endpoint + body per verb) is worth
/// pinning down, since a wrong `zone_or_output_id` key or control string silently
/// no-ops against Roon.
///
/// `RoonTransport` (the real actor) satisfies this with its existing `dispatch`.
protocol TransportDispatching: Sendable {
    func dispatch(_ endpoint: String, body: [String: Any]?) async throws
}

extension RoonTransport: TransportDispatching {}
