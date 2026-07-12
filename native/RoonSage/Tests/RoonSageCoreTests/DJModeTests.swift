import XCTest
@testable import RoonSageCore

final class DJModeTests: XCTestCase {
    private func track(
        _ id: String, artist: String, matchKey: String? = nil,
        moods: [String: Float] = [:]
    ) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(id: id, title: id, artist: artist, album: nil, imageKey: nil,
                                   matchKey: matchKey ?? id, bpm: 120, camelot: "8B", energy: 0.5,
                                   tags: [], moods: moods)
    }

    // MARK: Presets

    func testPresetAdventurousnessOrdering() {
        // Purist is the safest, Daredevil the boldest; ordering is monotone.
        XCTAssertLessThan(DJMode.purist.adventurousness, DJMode.superfan.adventurousness)
        XCTAssertLessThan(DJMode.superfan.adventurousness, DJMode.vibe.adventurousness)
        XCTAssertLessThan(DJMode.vibe.adventurousness, DJMode.wanderer.adventurousness)
        XCTAssertLessThan(DJMode.wanderer.adventurousness, DJMode.daredevil.adventurousness)
        for m in DJMode.allCases {
            XCTAssert((0...1).contains(m.adventurousness), "\(m) out of range")
        }
    }

    func testPresetArcs() {
        XCTAssertEqual(DJMode.wanderer.arc, .gentleRise)
        XCTAssertEqual(DJMode.daredevil.arc, .peak)
        XCTAssertEqual(DJMode.purist.arc, .smooth)
        XCTAssertEqual(DJMode.vibe.arc, .smooth)
        XCTAssertEqual(DJMode.superfan.arc, .smooth)
        XCTAssertEqual(DJMode.timekeeper.arc, .smooth)
    }

    func testMetadataPresentForEveryCase() {
        for m in DJMode.allCases {
            XCTAssertFalse(m.title.isEmpty)
            XCTAssertFalse(m.blurb.isEmpty)
            XCTAssertFalse(m.symbol.isEmpty)
        }
    }

    func testCodableRoundTrip() throws {
        for m in DJMode.allCases {
            let data = try JSONEncoder().encode(m)
            XCTAssertEqual(try JSONDecoder().decode(DJMode.self, from: data), m)
        }
    }

    // MARK: Gates

    func testProximityOnlyPersonasHaveNoGate() {
        let seed = track("s", artist: "X", moods: ["warm": 0.9])
        for m in [DJMode.purist, .wanderer, .daredevil] {
            XCTAssertNil(m.gate(seed: seed), "\(m) should not gate")
        }
    }

    func testSuperfanAdmitsOnlySameArtist() {
        let seed = track("s", artist: "Radiohead")
        guard let gate = DJMode.superfan.gate(seed: seed) else { return XCTFail("expected a gate") }
        XCTAssertTrue(gate(track("a", artist: "radiohead")))   // case-insensitive
        XCTAssertFalse(gate(track("b", artist: "Muse")))
    }

    func testSuperfanNoGateWhenSeedArtistUnknown() {
        let seed = track("s", artist: "")
        XCTAssertNil(DJMode.superfan.gate(seed: seed))
    }

    func testTimekeeperAdmitsOnlySameDecade() {
        let seed = track("s", artist: "X", matchKey: "seed")
        let years = ["seed": 1994, "same": 1997, "other": 2003]
        guard let gate = DJMode.timekeeper.gate(seed: seed, years: years) else { return XCTFail("expected a gate") }
        XCTAssertTrue(gate(track("t1", artist: "Y", matchKey: "same")))    // 1990s
        XCTAssertFalse(gate(track("t2", artist: "Y", matchKey: "other")))  // 2000s
        XCTAssertFalse(gate(track("t3", artist: "Y", matchKey: "unknown"))) // no year → out
    }

    func testTimekeeperNoGateWhenSeedYearUnknown() {
        let seed = track("s", artist: "X", matchKey: "seed")
        XCTAssertNil(DJMode.timekeeper.gate(seed: seed, years: [:]))
    }

    func testVibeHoldsDominantMood() {
        let seed = track("s", artist: "X", moods: ["melancholic": 0.8, "warm": 0.2])
        guard let gate = DJMode.vibe.gate(seed: seed) else { return XCTFail("expected a gate") }
        XCTAssertTrue(gate(track("a", artist: "Y", moods: ["melancholic": 0.7])))    // dominant match
        XCTAssertTrue(gate(track("b", artist: "Y", moods: ["warm": 0.6, "melancholic": 0.35]))) // ≥0.3 present
        XCTAssertFalse(gate(track("c", artist: "Y", moods: ["warm": 0.9, "melancholic": 0.1]))) // <0.3, not dominant
    }

    func testVibeNoGateWhenSeedHasNoMoods() {
        XCTAssertNil(DJMode.vibe.gate(seed: track("s", artist: "X")))
    }
}
