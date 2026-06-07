import XCTest
@testable import RoonProtocol

final class MOOFrameTests: XCTestCase {

    func testRequestRoundTrip() throws {
        let frame = try MOOFrame.request(
            RoonService.registry + "/register",
            requestID: 10,
            json: ["display_name": "RoonSage", "token": "abc123"]
        )
        let wire = frame.encode()
        let decoded = try MOOFrame.decode(wire)

        XCTAssertEqual(decoded.verb, .request)
        XCTAssertEqual(decoded.name, "com.roonlabs.registry:1/register")
        XCTAssertEqual(decoded.requestID, 10)

        let json = try XCTUnwrap(decoded.jsonBody() as? [String: Any])
        XCTAssertEqual(json["display_name"] as? String, "RoonSage")
        XCTAssertEqual(json["token"] as? String, "abc123")
    }

    func testContentLengthIsByteCount() throws {
        // Multi-byte body: "café" is 5 bytes UTF-8 but 4 characters.
        let frame = try MOOFrame.request("svc/x", requestID: 1, json: ["v": "café"])
        let wire = frame.encode()
        let text = String(data: wire, encoding: .utf8)!
        // {"v":"café"} -> 13 bytes UTF-8 (é is 2 bytes) vs 12 characters.
        XCTAssertTrue(text.contains("Content-Length: 13"), "header was: \(text)")
    }

    func testDecodeRegisteredReply() throws {
        let body = #"{"token":"tok-9","core_id":"core-xyz","display_name":"Living Room"}"#
        let raw = "MOO/1 COMPLETE Registered\n"
            + "Request-Id: 10\n"
            + "Content-Length: \(body.utf8.count)\n"
            + "Content-Type: application/json\n\n"
            + body
        let frame = try MOOFrame.decode(Data(raw.utf8))

        XCTAssertEqual(frame.verb, .complete)
        XCTAssertEqual(frame.name, "Registered")
        XCTAssertEqual(frame.requestID, 10)

        let json = try XCTUnwrap(frame.jsonBody() as? [String: Any])
        XCTAssertEqual(json["token"] as? String, "tok-9")
        XCTAssertEqual(json["core_id"] as? String, "core-xyz")
        XCTAssertEqual(json["display_name"] as? String, "Living Room")
    }

    func testDecodeServerPing() throws {
        let raw = "MOO/1 REQUEST com.roonlabs.ping:1/ping\nRequest-Id: 3\n\n"
        let frame = try MOOFrame.decode(Data(raw.utf8))
        XCTAssertEqual(frame.verb, .request)
        XCTAssertEqual(frame.requestID, 3)
        XCTAssertTrue(frame.isPing)
        XCTAssertNil(frame.body)
    }

    func testDecodeContinueChanged() throws {
        let body = #"{"zones_changed":[{"zone_id":"z1","display_name":"Office"}]}"#
        let raw = "MOO/1 CONTINUE Changed\n"
            + "Request-Id: 42\n"
            + "Content-Length: \(body.utf8.count)\n"
            + "Content-Type: application/json\n\n"
            + body
        let frame = try MOOFrame.decode(Data(raw.utf8))

        XCTAssertEqual(frame.verb, .continuation)
        XCTAssertEqual(frame.name, "Changed")
        XCTAssertEqual(frame.requestID, 42)
        let json = try XCTUnwrap(frame.jsonBody() as? [String: Any])
        XCTAssertNotNil(json["zones_changed"])
    }

    func testEncodeNoBodyComplete() {
        let frame = MOOFrame(verb: .complete, name: "Success", requestID: 5)
        let wire = String(data: frame.encode(), encoding: .utf8)
        XCTAssertEqual(wire, "MOO/1 COMPLETE Success\nRequest-Id: 5\n\n")
    }

    func testDecodeRejectsGarbage() {
        XCTAssertThrowsError(try MOOFrame.decode(Data("HELLO world\n\n".utf8)))
        XCTAssertThrowsError(try MOOFrame.decode(Data()))
    }
}
