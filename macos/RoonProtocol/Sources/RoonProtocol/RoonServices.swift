import Foundation

/// Roon service identifiers and protocol constants, mirrored from the
/// `node-roon-api` reference implementation (via pyroon 0.1.6).
public enum RoonService {
    public static let registry = "com.roonlabs.registry:1"
    public static let transport = "com.roonlabs.transport:2"
    public static let status = "com.roonlabs.status:1"
    public static let pairing = "com.roonlabs.pairing:1"
    public static let ping = "com.roonlabs.ping:1"
    public static let image = "com.roonlabs.image:1"
    public static let browse = "com.roonlabs.browse:1"
    public static let settings = "com.roonlabs.settings:1"
    public static let volumeControl = "com.roonlabs.volumecontrol:1"
    public static let sourceControl = "com.roonlabs.sourcecontrol:1"
}

public enum RoonProtocolConstants {
    /// SOOD discovery multicast group + port.
    public static let soodMulticastIP = "239.255.90.90"
    public static let soodPort: UInt16 = 9003

    /// Fixed SOOD service id every Roon Core advertises against.
    public static let soodServiceID = "00720724-5143-4a9b-abac-0e50cba674bb"

    /// Default transaction id used by the canonical discovery query
    /// (matches pyroon's shipped `.soodmsg` byte-for-byte).
    public static let soodDefaultTID = "c64e3888-f2f2-4c4a-9f89-2093ae4217a6"

    /// Browse pagination page size used by the Roon browse hierarchy.
    public static let pageSize = 100
}
