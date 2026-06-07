import Foundation

/// SOOD is Roon's UDP service-discovery wire format.
///
///     SOOD\x02<type><1bytelen><key><2bytelen><value>...
///
/// `type` is 'Q' (query) or 'R' (response). Keys are length-prefixed with one
/// big-endian byte, values with two big-endian bytes.
public struct SOODMessage: Equatable {
    public enum MessageType: Equatable {
        case query
        case response
    }

    public var type: MessageType
    public var properties: [String: String]

    public init(type: MessageType, properties: [String: String]) {
        self.type = type
        self.properties = properties
    }

    private static let prefix = Data([0x53, 0x4F, 0x4F, 0x44, 0x02]) // "SOOD" + 0x02

    public enum ParseError: Error, Equatable {
        case badPrefix
        case badType
        case truncated
    }
}

// MARK: - Query building

public extension SOODMessage {
    /// Build the discovery query datagram. With default arguments this is
    /// byte-for-byte identical to pyroon's shipped `.soodmsg`.
    static func makeQuery(
        serviceID: String = RoonProtocolConstants.soodServiceID,
        tid: String = RoonProtocolConstants.soodDefaultTID
    ) -> Data {
        var data = prefix
        data.append(0x51) // 'Q'
        appendProperty(&data, key: "query_service_id", value: serviceID)
        appendProperty(&data, key: "_tid", value: tid)
        return data
    }

    private static func appendProperty(_ data: inout Data, key: String, value: String) {
        let keyBytes = Data(key.utf8)
        let valueBytes = Data(value.utf8)
        // 1-byte key length (big-endian).
        data.append(UInt8(keyBytes.count))
        data.append(keyBytes)
        // 2-byte value length (big-endian).
        let len = UInt16(valueBytes.count)
        data.append(UInt8(len >> 8))
        data.append(UInt8(len & 0xFF))
        data.append(valueBytes)
    }
}

// MARK: - Response parsing

public extension SOODMessage {
    init(parsing data: Data) throws {
        guard data.starts(with: SOODMessage.prefix) else {
            throw ParseError.badPrefix
        }
        var cursor = data.startIndex + SOODMessage.prefix.count

        guard cursor < data.endIndex else { throw ParseError.truncated }
        let typeByte = data[cursor]
        cursor += 1
        let type: MessageType
        switch typeByte {
        case 0x51: type = .query     // 'Q'
        case 0x52: type = .response  // 'R'
        default: throw ParseError.badType
        }

        var props: [String: String] = [:]
        while cursor < data.endIndex {
            let key = try SOODMessage.readField(data, &cursor, lengthBytes: 1)
            let value = try SOODMessage.readField(data, &cursor, lengthBytes: 2)
            props[key] = value
        }

        self.init(type: type, properties: props)
    }

    private static func readField(
        _ data: Data, _ cursor: inout Data.Index, lengthBytes: Int
    ) throws -> String {
        guard cursor + lengthBytes <= data.endIndex else { throw ParseError.truncated }
        var length = 0
        for _ in 0..<lengthBytes {
            length = (length << 8) | Int(data[cursor])
            cursor += 1
        }
        guard cursor + length <= data.endIndex else { throw ParseError.truncated }
        let fieldData = data.subdata(in: cursor..<(cursor + length))
        cursor += length
        guard let string = String(data: fieldData, encoding: .utf8) else {
            throw ParseError.truncated
        }
        return string
    }
}

/// A discovered Roon Core, distilled from a SOOD response.
public struct DiscoveredRoonCore: Equatable {
    public let host: String
    public let httpPort: Int
    public let uniqueID: String
    public let name: String?
    public let displayVersion: String?

    public init?(host: String, soodResponse: SOODMessage) {
        guard soodResponse.type == .response,
              let portString = soodResponse.properties["http_port"],
              let port = Int(portString),
              let uniqueID = soodResponse.properties["unique_id"]
        else { return nil }
        self.host = host
        self.httpPort = port
        self.uniqueID = uniqueID
        self.name = soodResponse.properties["name"]
        self.displayVersion = soodResponse.properties["display_version"]
    }
}
