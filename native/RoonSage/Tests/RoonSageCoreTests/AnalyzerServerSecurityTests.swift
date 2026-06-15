@testable import AnalyzerCore
import XCTest

/// Covers the analyzer feature-server (5766) auth helpers added so the
/// feature/embedding corpus isn't open over ZeroTier/LAN.
final class AnalyzerServerSecurityTests: XCTestCase {

    func testConstantTimeEquals() {
        XCTAssertTrue(HTTPServer.constantTimeEquals("tok-abc", "tok-abc"))
        XCTAssertFalse(HTTPServer.constantTimeEquals("tok-abc", "tok-abd"))
        XCTAssertFalse(HTTPServer.constantTimeEquals("a", "aa"))
        XCTAssertTrue(HTTPServer.constantTimeEquals("", ""))
    }

    func testHeaderValueCaseInsensitive() {
        let req = "GET /features HTTP/1.1\r\nX-RoonSage-Token: abc\r\nAccept: */*\r\n\r\n"
        XCTAssertEqual(HTTPServer.headerValue("x-roonsage-token", in: req), "abc")
        XCTAssertNil(HTTPServer.headerValue("Authorization", in: req))
    }

    func testQueryValueDecodesPlusAndPercent() {
        XCTAssertEqual(HTTPServer.queryValue("q", in: "/text-embed?q=warm+jazz"), "warm jazz")
        XCTAssertEqual(HTTPServer.queryValue("q", in: "/text-embed?q=caf%C3%A9"), "café")
        XCTAssertNil(HTTPServer.queryValue("q", in: "/text-embed"))
    }
}
