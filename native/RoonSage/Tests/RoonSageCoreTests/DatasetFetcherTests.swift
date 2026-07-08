import AnalyzerCore
import Foundation
import XCTest

/// `DatasetFetcher.newestRelease` — pure parse of the GitHub Releases API
/// response, no network. Mirrors AnalyzerUpdater's release-picking logic but for
/// the `dataset-vN` tag namespace and `.db.gz` assets.
final class DatasetFetcherTests: XCTestCase {

    private func releasesJSON(_ releases: [(tag: String, assets: [String])]) -> Data {
        let arr = releases.map { r -> [String: Any] in
            [
                "tag_name": r.tag,
                "assets": r.assets.map { name in
                    ["name": name, "browser_download_url": "https://example.com/\(name)"]
                },
            ]
        }
        return try! JSONSerialization.data(withJSONObject: arr)
    }

    func testPicksNewestDatasetTagWithGzAsset() {
        let data = releasesJSON([
            (tag: "v1.10.150", assets: ["RoonSage.dmg"]),                       // wrong prefix — ignored
            (tag: "dataset-v1", assets: ["metadata.db.gz"]),
            (tag: "dataset-v2", assets: ["metadata.db.gz"]),
            (tag: "analyzer-v1.1.125", assets: ["RoonSageAnalyzer.dmg"]),        // wrong prefix — ignored
        ])
        let release = DatasetFetcher.newestRelease(fromReleasesJSON: data)
        XCTAssertEqual(release?.version, "2")
        XCTAssertEqual(release?.downloadURL, "https://example.com/metadata.db.gz")
    }

    func testIgnoresDatasetReleaseWithoutGzAsset() {
        let data = releasesJSON([
            (tag: "dataset-v1", assets: ["README.md"]),   // no .db.gz asset — skip
            (tag: "dataset-v2", assets: ["metadata.db.gz"]),
        ])
        let release = DatasetFetcher.newestRelease(fromReleasesJSON: data)
        XCTAssertEqual(release?.version, "2", "the tag without a usable asset must not win")
    }

    func testNoDatasetReleaseYieldsNil() {
        let data = releasesJSON([(tag: "v1.10.150", assets: ["RoonSage.dmg"])])
        XCTAssertNil(DatasetFetcher.newestRelease(fromReleasesJSON: data))
    }

    func testMalformedJSONYieldsNil() {
        XCTAssertNil(DatasetFetcher.newestRelease(fromReleasesJSON: Data("not json".utf8)))
    }
}
