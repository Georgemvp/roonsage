import XCTest
@testable import RoonSageCore

final class JourneysTests: XCTestCase {
    private func track(_ id: String, matchKey: String? = nil) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(id: id, title: id, artist: "A", album: nil, imageKey: nil,
                                   matchKey: matchKey ?? id, bpm: 120, camelot: "8B", energy: 0.5, tags: [])
    }

    // MARK: Time Machine ordering

    func testChronologicalOrderNonDecreasing() {
        let lib = [track("a"), track("b"), track("c"), track("d")]
        let years = ["a": 2001, "b": 1985, "c": 1972, "d": 1999]
        let ordered = RoonClient.timeMachineOrder(lib, years: years, count: 40)
        let outYears = ordered.map { years[$0.matchKey]! }
        XCTAssertEqual(outYears, outYears.sorted(), "journey must run old → new")
        XCTAssertEqual(ordered.count, 4)
    }

    func testYearlessTracksExcluded() {
        let lib = [track("dated"), track("undated")]
        let years = ["dated": 1990]   // "undated" has no year
        let ordered = RoonClient.timeMachineOrder(lib, years: years, count: 40)
        XCTAssertEqual(ordered.map(\.id), ["dated"])
    }

    func testImplausibleYearsExcluded() {
        let lib = [track("ok"), track("bogus")]
        let years = ["ok": 1994, "bogus": 3500]   // out of isPlausibleYear range
        let ordered = RoonClient.timeMachineOrder(lib, years: years, count: 40)
        XCTAssertEqual(ordered.map(\.id), ["ok"])
    }

    func testEmptyWhenNoDatedTracks() {
        XCTAssertTrue(RoonClient.timeMachineOrder([track("a")], years: [:], count: 40).isEmpty)
        XCTAssertTrue(RoonClient.timeMachineOrder([track("a")], years: ["a": 1990], count: 0).isEmpty)
    }

    func testCountCapAndDecadeSpread() {
        // 30 tracks spread over three decades; a small count must still span them,
        // not clump in one decade.
        var lib: [DatabaseManager.SonicTrack] = []
        var years: [String: Int] = [:]
        for decade in [1970, 1990, 2010] {
            for i in 0..<10 {
                let id = "\(decade)-\(i)"
                lib.append(track(id))
                years[id] = decade + i
            }
        }
        let ordered = RoonClient.timeMachineOrder(lib, years: years, count: 6)
        XCTAssertLessThanOrEqual(ordered.count, 6)
        let decadesHit = Set(ordered.map { (years[$0.matchKey]! / 10) * 10 })
        XCTAssertEqual(decadesHit, [1970, 1990, 2010], "each decade must be represented")
        let outYears = ordered.map { years[$0.matchKey]! }
        XCTAssertEqual(outYears, outYears.sorted())
    }
}
