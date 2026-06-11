import Foundation
import XCTest
@testable import RoonSageCore

final class DiskImageCacheTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskImageCacheTests-\(UUID().uuidString)", isDirectory: true)
        DiskImageCache.directoryOverride = tmp
    }

    override func tearDown() {
        DiskImageCache.directoryOverride = nil
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    func testStoreThenReadRoundTrips() {
        let url = URL(string: "http://core:9330/api/image/abc?width=120")!
        let bytes = Data((0..<256).map { UInt8($0 & 0xff) })
        DiskImageCache.store(bytes, for: url)
        XCTAssertEqual(DiskImageCache.data(for: url), bytes)
    }

    func testMissReturnsNil() {
        let url = URL(string: "http://core:9330/api/image/never?width=120")!
        XCTAssertNil(DiskImageCache.data(for: url))
    }

    func testFilenameIsStableAndUrlSpecific() {
        let a = URL(string: "http://core/image/x?width=100")!
        let b = URL(string: "http://core/image/x?width=200")!   // different size → different entry
        XCTAssertEqual(DiskImageCache.filename(for: a), DiskImageCache.filename(for: a))
        XCTAssertNotEqual(DiskImageCache.filename(for: a), DiskImageCache.filename(for: b))
        // Hex SHA-256 → 64 chars, path-safe.
        XCTAssertEqual(DiskImageCache.filename(for: a).count, 64)
    }

    func testEmptyDataNotStored() {
        let url = URL(string: "http://core/image/empty")!
        DiskImageCache.store(Data(), for: url)
        XCTAssertNil(DiskImageCache.data(for: url))
    }

    func testPruneEvictsOldestBeyondLimit() throws {
        // Three 10 KB blobs; prune to ~15 KB should drop the oldest.
        let blob = Data(repeating: 7, count: 10 * 1024)
        let urls = (0..<3).map { URL(string: "http://core/image/\($0)")! }
        for (i, u) in urls.enumerated() {
            DiskImageCache.store(blob, for: u)
            // Stagger modification dates so "oldest" is well-defined.
            let f = tmp.appendingPathComponent(DiskImageCache.filename(for: u))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(1000 + i))], ofItemAtPath: f.path)
        }
        DiskImageCache.prune(limitBytes: 15 * 1024)
        XCTAssertNil(DiskImageCache.data(for: urls[0]), "oldest should be evicted")
        XCTAssertNotNil(DiskImageCache.data(for: urls[2]), "newest should survive")
    }
}
