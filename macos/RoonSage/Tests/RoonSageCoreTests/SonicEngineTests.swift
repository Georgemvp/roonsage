import XCTest
@testable import RoonSageCore

final class SonicSimilarityTests: XCTestCase {
    func testTempoDistance() {
        XCTAssertEqual(SonicSimilarity.tempoDistance(120, 120), 0, accuracy: 0.001)
        // Double-time is treated as close.
        XCTAssertLessThan(SonicSimilarity.tempoDistance(120, 60), 0.05)
        // A 40 BPM gap saturates to 1.
        XCTAssertEqual(SonicSimilarity.tempoDistance(120, 160), 1, accuracy: 0.001)
        // Missing data → neutral.
        XCTAssertEqual(SonicSimilarity.tempoDistance(nil, 120), 0.5, accuracy: 0.001)
    }

    func testKeyDistance() {
        XCTAssertEqual(SonicSimilarity.keyDistance("8A", "8A"), 0, accuracy: 0.001)
        // 8A's compatible set includes 8B / 9A / 7A.
        XCTAssertEqual(SonicSimilarity.keyDistance("8A", "9A"), 0.15, accuracy: 0.001)
        // Far apart on the wheel is large.
        XCTAssertGreaterThan(SonicSimilarity.keyDistance("1A", "7A"), 0.7)
        XCTAssertEqual(SonicSimilarity.keyDistance("", "8A"), 0.5, accuracy: 0.001)
    }

    func testTagDistance() {
        XCTAssertEqual(SonicSimilarity.tagDistance(["a", "b"], ["a", "b"]), 0, accuracy: 0.001)
        XCTAssertEqual(SonicSimilarity.tagDistance(["a"], ["b"]), 1, accuracy: 0.001)
        XCTAssertEqual(SonicSimilarity.tagDistance([], ["b"]), 0.5, accuracy: 0.001)
        XCTAssertEqual(SonicSimilarity.tagDistance(["a", "b"], ["b", "c"]), 1 - 1.0/3.0, accuracy: 0.001)
    }

    func testSimilarRankingAndSelfExclusion() {
        func t(_ id: String, bpm: Double, camelot: String, energy: Double, tags: [String]) -> DatabaseManager.SonicTrack {
            DatabaseManager.SonicTrack(id: id, title: id, artist: "A-\(id)", album: nil, imageKey: nil,
                                       matchKey: id, bpm: bpm, camelot: camelot, energy: energy, tags: tags)
        }
        let seed = t("seed", bpm: 120, camelot: "8A", energy: 0.5, tags: ["warm"])
        let near = t("near", bpm: 122, camelot: "8A", energy: 0.52, tags: ["warm"])
        let far  = t("far", bpm: 175, camelot: "2B", energy: 0.95, tags: ["harsh"])
        let lib = [seed, near, far]

        let result = SonicEngine.similar(to: seed, in: lib, limit: 10)
        XCTAssertEqual(result.count, 2)              // seed excluded
        XCTAssertEqual(result.first?.track.id, "near")  // closest first
        XCTAssertGreaterThan(result[0].similarity, result[1].similarity)
    }

    func testProfileBasics() {
        func t(_ bpm: Double, _ camelot: String, _ energy: Double, _ tags: [String]) -> DatabaseManager.SonicTrack {
            DatabaseManager.SonicTrack(id: UUID().uuidString, title: "x", artist: nil, album: nil, imageKey: nil,
                                       matchKey: UUID().uuidString, bpm: bpm, camelot: camelot, energy: energy, tags: tags)
        }
        let p = SonicEngine.profile(of: [t(120, "8B", 0.5, ["a"]), t(120, "8B", 0.5, ["a", "b"])])
        XCTAssertEqual(p.sampleCount, 2)
        XCTAssertEqual(p.avgBPM, 120, accuracy: 0.001)
        XCTAssertEqual(p.majorAffinity, 1, accuracy: 0.001)   // both B = major
        XCTAssertEqual(p.topTags.first?.tag, "a")
    }
}
