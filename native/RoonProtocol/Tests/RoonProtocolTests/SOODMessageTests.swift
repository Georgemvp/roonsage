import XCTest
@testable import RoonProtocol

final class SOODMessageTests: XCTestCase {

    func testQueryMatchesCanonicalLayout() {
        let query = SOODMessage.makeQuery()

        // pyroon's shipped .soodmsg is exactly 104 bytes.
        XCTAssertEqual(query.count, 104)
        // Header: "SOOD" + 0x02 + 'Q'.
        XCTAssertEqual(Array(query.prefix(6)),
                       [0x53, 0x4F, 0x4F, 0x44, 0x02, 0x51])
    }

    func testQueryRoundTrips() throws {
        let query = SOODMessage.makeQuery()
        let parsed = try SOODMessage(parsing: query)

        XCTAssertEqual(parsed.type, .query)
        XCTAssertEqual(parsed.properties["query_service_id"],
                       RoonProtocolConstants.soodServiceID)
        XCTAssertEqual(parsed.properties["_tid"],
                       RoonProtocolConstants.soodDefaultTID)
    }

    func testParseResponse() throws {
        // Hand-build a minimal SOOD response: SOOD\x02R + properties.
        var data = Data([0x53, 0x4F, 0x4F, 0x44, 0x02, 0x52]) // ...R
        func add(_ key: String, _ value: String) {
            let k = Data(key.utf8), v = Data(value.utf8)
            data.append(UInt8(k.count)); data.append(k)
            let len = UInt16(v.count)
            data.append(UInt8(len >> 8)); data.append(UInt8(len & 0xFF)); data.append(v)
        }
        add("name", "Living Room")
        add("unique_id", "core-abc-123")
        add("http_port", "9330")
        add("display_version", "2.0 (build 1488)")

        let parsed = try SOODMessage(parsing: data)
        XCTAssertEqual(parsed.type, .response)

        let core = try XCTUnwrap(DiscoveredRoonCore(host: "192.168.1.50", soodResponse: parsed))
        XCTAssertEqual(core.host, "192.168.1.50")
        XCTAssertEqual(core.httpPort, 9330)
        XCTAssertEqual(core.uniqueID, "core-abc-123")
        XCTAssertEqual(core.name, "Living Room")
        XCTAssertEqual(core.displayVersion, "2.0 (build 1488)")
    }

    func testParseRejectsBadPrefix() {
        XCTAssertThrowsError(try SOODMessage(parsing: Data("NOPE".utf8))) { error in
            XCTAssertEqual(error as? SOODMessage.ParseError, .badPrefix)
        }
    }

    func testParseRejectsTruncatedValue() {
        // Claims a 2-byte value length but provides no value bytes.
        let data = Data([0x53, 0x4F, 0x4F, 0x44, 0x02, 0x52,
                         0x04, 0x6E, 0x61, 0x6D, 0x65, // key "name"
                         0x00, 0x10])                  // value len 16, then EOF
        XCTAssertThrowsError(try SOODMessage(parsing: data)) { error in
            XCTAssertEqual(error as? SOODMessage.ParseError, .truncated)
        }
    }
}
