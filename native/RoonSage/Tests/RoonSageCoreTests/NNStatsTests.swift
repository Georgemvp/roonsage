import XCTest
@testable import RoonSageCore

final class NNStatsTests: XCTestCase {
    private func track(_ id: String, emb: [Float]) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(id: id, title: id, artist: "a", album: nil, imageKey: nil,
                                   matchKey: id, bpm: 120, camelot: "8B", rmsEnergy: 0.5, tags: [],
                                   embedding: emb)
    }

    /// A tight cluster: every NN similarity ≈ 1 → mean high, σ small.
    func testTightClusterHasHighMeanLowStd() {
        let tracks = (0..<20).map { i -> DatabaseManager.SonicTrack in
            let angle = Float(i) * 0.01
            return track("t\(i)", emb: [cos(angle), sin(angle), 0])
        }
        let idx = VectorIndex(tracks: tracks)!
        let stats = idx.nnSimilarityStats(sampleCount: 20)!
        XCTAssertGreaterThan(stats.mean, 0.99)
        XCTAssertLessThan(stats.std, 0.01)
        XCTAssertLessThan(stats.floor(sigmas: 2), stats.mean)
    }

    /// Too few vectors → nil (no meaningful calibration).
    func testTooSmallLibraryReturnsNil() {
        let tracks = (0..<4).map { track("t\($0)", emb: [Float($0), 1, 0]) }
        let idx = VectorIndex(tracks: tracks)!
        XCTAssertNil(idx.nnSimilarityStats())
    }

    /// The dial in σ's: adventurous floors sit lower than cosy ones.
    func testAdventurousnessLowersTheFloor() {
        let stats = VectorIndex.NNStats(mean: 0.8, std: 0.05)
        let cosy = RadioEngine.Options.floor(stats: stats, adventurousness: 0)
        let wild = RadioEngine.Options.floor(stats: stats, adventurousness: 1)
        XCTAssertEqual(cosy, 0.75, accuracy: 1e-9)   // μ − 1σ
        XCTAssertEqual(wild, 0.65, accuracy: 1e-9)   // μ − 3σ
        XCTAssertLessThan(wild, cosy)
    }

    /// The floor actually rejects: a far-out candidate that would otherwise
    /// rank (high centroid score via the seed) is gone when the floor is set.
    func testRankRespectsFloor() {
        var tracks = (0..<12).map { i -> DatabaseManager.SonicTrack in
            let angle = Float(i) * 0.02
            return track("near\(i)", emb: [cos(angle), sin(angle), 0])
        }
        tracks.append(track("far", emb: [0, 0, 1]))
        let idx = VectorIndex(tracks: tracks)!
        let seed = tracks[0]
        let optsNoFloor = RadioEngine.Options(adventurousness: 0.5, poolLimit: 13, sequence: false)
        let optsFloor = RadioEngine.Options(adventurousness: 0.5, poolLimit: 13, sequence: false,
                                            similarityFloor: 0.5)
        let without = RadioEngine.rank(seeds: [seed], library: tracks, index: idx, options: optsNoFloor)
        let with = RadioEngine.rank(seeds: [seed], library: tracks, index: idx, options: optsFloor)
        XCTAssertTrue(without.contains { $0.track.id == "far" }, "no floor → the outlier ranks")
        XCTAssertFalse(with.contains { $0.track.id == "far" }, "floor → the outlier is rejected")
    }
}
