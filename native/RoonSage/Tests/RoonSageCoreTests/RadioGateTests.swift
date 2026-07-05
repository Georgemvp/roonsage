import XCTest
@testable import RoonSageCore

final class RadioGateTests: XCTestCase {

    private func st(_ id: String, artist: String = "A", energy: Double? = nil, bpm: Double? = nil,
                    moods: [String: Float] = [:], matchKey: String? = nil) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(id: id, title: "T\(id)", artist: artist, album: nil, imageKey: nil,
                                   matchKey: matchKey ?? "mk\(id)", bpm: bpm, camelot: "8A",
                                   energy: energy, tags: [], embedding: nil, moods: moods)
    }

    func testActivityGateMatchesProfile() throws {
        let gate = try XCTUnwrap(RoonClient.bucketGate(radioID: "activity:workout"))
        XCTAssertTrue(gate(st("1", energy: 0.9, bpm: 140)))
        XCTAssertFalse(gate(st("2", energy: 0.2, bpm: 70)), "a ballad must not pass the workout gate")
    }

    func testActivityGateWorksOnCompressedEnergyViaCalibration() throws {
        // Library whose energy signal maxes at ~0.35 (the RMS bug). WITHOUT
        // calibration, workout's absolute >=0.70 matches nothing. WITH it, the
        // top-percentile fast tracks pass.
        let lib = (0..<20).map { st("\($0)", energy: Double($0) * 0.0175, bpm: 130) }
        let cal = TitleGrounding.Calibration.compute(library: lib)
        let gate = try XCTUnwrap(RoonClient.bucketGate(radioID: "activity:workout", calibration: cal))
        XCTAssertTrue(gate(st("hot", energy: 0.34, bpm: 130)), "top-of-library energy passes workout")
        XCTAssertFalse(gate(st("mid", energy: 0.10, bpm: 130)), "low-percentile energy does not")
        // Uncalibrated absolute gate would reject even the hottest track here.
        let absGate = try XCTUnwrap(RoonClient.bucketGate(radioID: "activity:workout"))
        XCTAssertFalse(absGate(st("hot2", energy: 0.34, bpm: 130)))
    }

    func testMoodGateDominantOrPresent() throws {
        let gate = try XCTUnwrap(RoonClient.bucketGate(radioID: "mood:relaxed"))
        XCTAssertTrue(gate(st("1", moods: ["relaxed": 0.6, "happy": 0.2])))   // dominant
        XCTAssertTrue(gate(st("2", moods: ["happy": 0.5, "relaxed": 0.35]))) // clearly present
        XCTAssertFalse(gate(st("3", moods: ["aggressive": 0.7, "relaxed": 0.1])))
        XCTAssertFalse(gate(st("4")))
    }

    func testGenreGate() throws {
        let genres: [String: Set<String>] = ["1": ["House", "Techno"], "2": ["Jazz"]]
        let gate = try XCTUnwrap(RoonClient.bucketGate(radioID: "genre:house", genres: genres))
        XCTAssertTrue(gate(st("1")))
        XCTAssertFalse(gate(st("2")))
        XCTAssertFalse(gate(st("3")))
    }

    func testDecadeGate() throws {
        let years = ["mk1": 1994, "mk2": 2011]
        let gate = try XCTUnwrap(RoonClient.bucketGate(radioID: "decade:1990", years: years))
        XCTAssertTrue(gate(st("1")))
        XCTAssertFalse(gate(st("2")))
        XCTAssertFalse(gate(st("3")), "unknown year must not pass a decade gate")
    }

    func testArtistAndSonicAndTrackHaveNoGate() {
        XCTAssertNil(RoonClient.bucketGate(radioID: "artist:radiohead"))
        XCTAssertNil(RoonClient.bucketGate(radioID: "sonic:12345"))
        XCTAssertNil(RoonClient.bucketGate(radioID: "track:mk1"))
        XCTAssertNil(RoonClient.bucketGate(radioID: "geen-dubbelepunt"))
    }

    func testGatedWithRelaxationTopsUpToMinKeep() {
        let ranked = Array(0..<10)
        // Only 2 evens < minKeep 5 → topped up with the best 3 odds, evens first.
        let out = RoonClient.gatedWithRelaxation(ranked, gate: { $0 % 2 == 0 && $0 < 4 }, minKeep: 5)
        XCTAssertEqual(Array(out.prefix(2)), [0, 2])
        XCTAssertEqual(out.count, 5)
        // Enough matches → no relaxation at all.
        let strict = RoonClient.gatedWithRelaxation(ranked, gate: { $0 % 2 == 0 }, minKeep: 3)
        XCTAssertEqual(strict, [0, 2, 4, 6, 8])
    }

    func testBuildRadioCandidatesHonoursGate() {
        // Rule-based path (index nil): seed + neighbours; the gate keeps only
        // high-energy neighbours (relaxation off with a tiny minKeep).
        // The matching pool must exceed the relaxation floor (radioBatchSize×3),
        // else topping-up is correct behaviour rather than a leak.
        let seed = st("s", artist: "Seed", energy: 0.9, bpm: 130)
        var lib = [seed]
        lib += (0..<80).map { st("hi\($0)", artist: "H\($0)", energy: 0.85, bpm: 135) }
        lib += (0..<30).map { st("lo\($0)", artist: "L\($0)", energy: 0.1, bpm: 60) }
        let pool = RoonClient.buildRadioCandidates(
            seedIds: [seed.id], lib: lib, index: nil, seed: "",
            gate: { ($0.energy ?? 0) >= 0.7 })
        XCTAssertFalse(pool.isEmpty)
        // Nothing from the low-energy half may appear (the high-energy pool is
        // plenty to satisfy the relaxation minimum).
        XCTAssertFalse(pool.contains { $0.id.hasPrefix("lo") },
                       "low-energy tracks leaked past the gate: \(pool.map(\.id))")
    }
}
