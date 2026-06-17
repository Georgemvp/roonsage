import XCTest
@testable import RoonSageCore

/// Pure-logic tests for the Sonic Radio daily-shuffle and candidate builder.
final class SonicRadioTests: XCTestCase {

    private func track(_ id: String, artist: String, bpm: Double, camelot: String,
                       energy: Double, tags: [String]) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(id: id, title: id, artist: artist, album: nil, imageKey: nil,
                                   matchKey: id, bpm: bpm, camelot: camelot, energy: energy, tags: tags)
    }

    // MARK: Deterministic hashing

    func testSeed64IsStableAndDistinct() {
        XCTAssertEqual(RoonClient.seed64("2026-06-16"), RoonClient.seed64("2026-06-16"))
        XCTAssertNotEqual(RoonClient.seed64("2026-06-16"), RoonClient.seed64("2026-06-17"))
    }

    // MARK: Daily shuffle

    func testDailyShuffleIsDeterministicPerSeed() {
        let items = Array(0..<50)
        let a = RoonClient.dailyShuffled(items, seed: "2026-06-16")
        let b = RoonClient.dailyShuffled(items, seed: "2026-06-16")
        let c = RoonClient.dailyShuffled(items, seed: "2026-06-17")
        XCTAssertEqual(a, b)                       // same day → same order
        XCTAssertNotEqual(a, c)                    // next day → rotated
        XCTAssertEqual(a.sorted(), items)          // no elements lost or added
    }

    // MARK: Candidate building

    func testBuildCandidatesLeadsOnArtistAndDedups() {
        // Two tracks by the seed artist + several neighbours.
        let own1 = track("own1", artist: "Boards", bpm: 100, camelot: "8A", energy: 0.5, tags: ["warm", "ambient"])
        let own2 = track("own2", artist: "Boards", bpm: 102, camelot: "8A", energy: 0.52, tags: ["warm"])
        let near1 = track("near1", artist: "Other A", bpm: 101, camelot: "8A", energy: 0.51, tags: ["warm"])
        let near2 = track("near2", artist: "Other B", bpm: 99, camelot: "8B", energy: 0.5, tags: ["ambient"])
        let far = track("far", artist: "Other C", bpm: 178, camelot: "2B", energy: 0.97, tags: ["harsh"])
        let lib = [own1, own2, near1, near2, far]

        let out = RoonClient.buildRadioCandidates(
            seedIds: ["own1", "own2"], lib: lib, index: nil, seed: "2026-06-16")

        // Includes the artist's own tracks plus neighbours, no duplicates.
        XCTAssertEqual(out.count, Set(out.map { $0.id }).count, "no duplicate tracks")
        XCTAssertTrue(out.count >= 4)
        // Station opens on one of the seed artist's own tracks.
        XCTAssertTrue(["own1", "own2"].contains(out.first?.id), "leads on a seed-artist track")
        // The sonically distant track is still in the pool (radio is endless, not strict).
        XCTAssertTrue(out.contains { $0.id == "far" })
    }

    func testBuildCandidatesIsDeterministicPerSeed() {
        let own = track("own", artist: "X", bpm: 120, camelot: "8A", energy: 0.5, tags: ["a"])
        let n1 = track("n1", artist: "Y", bpm: 121, camelot: "8A", energy: 0.5, tags: ["a"])
        let n2 = track("n2", artist: "Z", bpm: 119, camelot: "8B", energy: 0.5, tags: ["a"])
        let lib = [own, n1, n2]

        let a = RoonClient.buildRadioCandidates(seedIds: ["own"], lib: lib, index: nil, seed: "day")
        let b = RoonClient.buildRadioCandidates(seedIds: ["own"], lib: lib, index: nil, seed: "day")
        XCTAssertEqual(a.map { $0.id }, b.map { $0.id })
    }

    func testBuildCandidatesEmptyWhenNoSeedTracksPresent() {
        let lib = [track("a", artist: "A", bpm: 120, camelot: "8A", energy: 0.5, tags: [])]
        let out = RoonClient.buildRadioCandidates(seedIds: ["missing"], lib: lib, index: nil, seed: "day")
        XCTAssertTrue(out.isEmpty)
    }

    func testBuildCandidatesExcludesDislikedNeighbours() {
        let own = track("own", artist: "X", bpm: 120, camelot: "8A", energy: 0.5, tags: ["a"])
        let good = track("good", artist: "Y", bpm: 121, camelot: "8A", energy: 0.5, tags: ["a"])
        let bad = track("bad", artist: "Z", bpm: 119, camelot: "8B", energy: 0.5, tags: ["a"])
        let lib = [own, good, bad]

        // matchKey == id in the test helper, so disliking "bad" drops it.
        let out = RoonClient.buildRadioCandidates(
            seedIds: ["own"], lib: lib, index: nil, seed: "day", disliked: ["bad"])
        XCTAssertFalse(out.contains { $0.id == "bad" }, "disliked neighbour is excluded")
        XCTAssertTrue(out.contains { $0.id == "good" }, "other neighbours remain")
    }
}
