@testable import RoonSageCore
import XCTest

/// Covers the pure Qobuz streaming request-signing (MD5 + assembly order). The
/// network call itself can't be unit-tested (live API + subscription), but the
/// signature is the part that must be byte-exact, so it's pinned here.
final class QobuzStreamTests: XCTestCase {
    func testMD5KnownVectors() {
        XCTAssertEqual(QobuzStream.md5Hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(QobuzStream.md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e")
    }

    func testSignatureBaseAssemblyOrder() {
        let base = QobuzStream.signatureBase(formatID: 6, intent: "stream", trackID: 12345, timestamp: 1_700_000_000)
        XCTAssertEqual(base, "trackgetFileUrlformat_id6intentstreamtrack_id123451700000000")
    }

    func testRequestSignatureIsMD5OfBasePlusSecret() {
        let secret = "s3cr3t"
        let expected = QobuzStream.md5Hex("trackgetFileUrlformat_id6intentstreamtrack_id123451700000000" + secret)
        let sig = QobuzStream.requestSignature(
            formatID: 6, intent: "stream", trackID: 12345, timestamp: 1_700_000_000, appSecret: secret)
        XCTAssertEqual(sig, expected)
        XCTAssertEqual(sig.count, 32)
    }
}
