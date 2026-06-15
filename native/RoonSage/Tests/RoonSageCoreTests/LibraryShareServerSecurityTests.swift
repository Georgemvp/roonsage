@testable import RoonSageCore
import XCTest

/// Covers the share-server hardening: a malformed Content-Length must never
/// produce an inverted body slice (which crashed the always-on process), the
/// token compare must be constant-time-correct, and header parsing must be
/// case-insensitive.
final class LibraryShareServerSecurityTests: XCTestCase {

    private func header(contentLength: String) -> String {
        "POST /command HTTP/1.1\r\nHost: x\r\nContent-Length: \(contentLength)\r\n\r\n"
    }

    func testContentLengthNegativeClampsToZero() {
        XCTAssertEqual(LibraryShareServer.contentLength(header(contentLength: "-1")), 0)
        XCTAssertEqual(LibraryShareServer.contentLength(header(contentLength: "-99999999")), 0)
    }

    func testContentLengthOverflowCapsAt32MB() {
        let cap = 32 * 1024 * 1024
        XCTAssertEqual(LibraryShareServer.contentLength(header(contentLength: "999999999999")), cap)
        XCTAssertEqual(LibraryShareServer.contentLength(header(contentLength: "\(Int.max)")), cap)
    }

    func testContentLengthNormalValuePreserved() {
        XCTAssertEqual(LibraryShareServer.contentLength(header(contentLength: "512")), 512)
    }

    func testContentLengthMissingOrGarbageIsZero() {
        XCTAssertEqual(LibraryShareServer.contentLength("GET / HTTP/1.1\r\n\r\n"), 0)
        XCTAssertEqual(LibraryShareServer.contentLength(header(contentLength: "abc")), 0)
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(LibraryShareServer.constantTimeEquals("a1b2c3", "a1b2c3"))
        XCTAssertFalse(LibraryShareServer.constantTimeEquals("a1b2c3", "a1b2c4"))
        XCTAssertFalse(LibraryShareServer.constantTimeEquals("short", "longer-token"))
        XCTAssertTrue(LibraryShareServer.constantTimeEquals("", ""))
        XCTAssertFalse(LibraryShareServer.constantTimeEquals("", "x"))
    }

    func testHeaderValueCaseInsensitive() {
        let h = "GET /x HTTP/1.1\r\nX-RoonSage-Token: secret123\r\n\r\n"
        XCTAssertEqual(LibraryShareServer.headerValue("x-roonsage-token", in: h), "secret123")
        XCTAssertEqual(LibraryShareServer.headerValue("X-RoonSage-Token", in: h), "secret123")
    }

    func testHeaderValueMissingIsNil() {
        let h = "GET /x HTTP/1.1\r\nHost: y\r\n\r\n"
        XCTAssertNil(LibraryShareServer.headerValue("X-RoonSage-Token", in: h))
    }
}
