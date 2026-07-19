@testable import RoonSageCore
import XCTest

/// Track E5d — Similar / Fingerprint / Alchemy / Song Path use the CLAP
/// VectorIndex when one is supplied, and fall back to rule-based otherwise.
final class SonicEngineEmbeddingTests: XCTestCase {
    private func track(_ id: String, _ emb: [Float], camelot: String = "8B", bpm: Double = 120) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(
            id: id, title: id, artist: id, album: "Al", imageKey: nil, matchKey: id,
            bpm: bpm, camelot: camelot, rmsEnergy: 0.5, tags: [], embedding: emb)
    }

    private func lib() -> [DatabaseManager.SonicTrack] {
        [track("x", [1, 0, 0, 0]),
         track("x2", [0.96, 0.28, 0, 0]),
         track("y", [0, 1, 0, 0]),
         track("z", [0, 0, 1, 0])]
    }

    func testSimilarUsesEmbeddingIndex() throws {
        let tracks = lib()
        let index = try XCTUnwrap(VectorIndex(tracks: tracks))
        let hits = SonicEngine.similar(to: tracks[0], in: tracks, limit: 2, index: index)
        XCTAssertEqual(hits.first?.track.id, "x2", "cosine-nearest neighbour")
    }

    func testAlchemyUsesEmbeddingIndex() throws {
        let tracks = lib()
        let index = try XCTUnwrap(VectorIndex(tracks: tracks))
        // add x, subtract y -> push toward x, away from y; x2 (mostly-x) should win.
        let r = SonicEngine.alchemy(add: [tracks[0]], subtract: [tracks[2]],
                                    in: tracks, limit: 3, index: index)
        XCTAssertEqual(r.first?.track.id, "x2")
        XCTAssertFalse(r.contains { $0.track.id == "x" }, "add seed excluded")
    }

    func testSongPathEmbeddingEndpointsAndBridge() throws {
        let tracks = lib()
        let index = try XCTUnwrap(VectorIndex(tracks: tracks))
        let path = SongPaths.find(from: tracks[0], to: tracks[2], library: tracks,
                                  maxSteps: 4, index: index)
        XCTAssertEqual(path.first?.track.id, "x")
        XCTAssertEqual(path.last?.track.id, "y")
        XCTAssertGreaterThanOrEqual(path.count, 2)
    }

    /// Gap D: de SUBTRACT-gate dropt kandidaten die dichter bij de subtract-
    /// centroid liggen dan bij de add-centroid — ook als de gebogen query-
    /// vector ze nog net zou toelaten.
    func testAlchemySubtractGateDropsNearSubtract() throws {
        var tracks = lib()
        tracks.append(track("mix", [0.6, 0.8, 0, 0]))   // dichter bij y (subtract) dan x (add)
        let index = try XCTUnwrap(VectorIndex(tracks: tracks))
        let r = SonicEngine.alchemy(add: [tracks[0]], subtract: [tracks[2]],
                                    in: tracks, limit: 4, index: index)
        XCTAssertFalse(r.contains { $0.track.id == "mix" },
                       "kandidaat aan de subtract-kant van de scheidslijn moet eruit")
        XCTAssertEqual(r.first?.track.id, "x2", "add-zijde blijft gewoon winnen")
    }

    /// Gap D: temperatuur 0 = exact het oude top-N-gedrag; temperatuur > 0 is
    /// deterministisch per seed (zelfde seed → zelfde selectie).
    func testAlchemyTemperatureDeterministicPerSeed() throws {
        let tracks = lib()
        let index = try XCTUnwrap(VectorIndex(tracks: tracks))
        let plain = SonicEngine.alchemy(add: [tracks[0]], subtract: [], in: tracks,
                                        limit: 3, index: index)
        let zero = SonicEngine.alchemy(add: [tracks[0]], subtract: [], in: tracks,
                                       limit: 3, index: index, temperature: 0)
        XCTAssertEqual(plain.map(\.track.id), zero.map(\.track.id), "T=0 wijzigt niets")

        let a = SonicEngine.alchemy(add: [tracks[0]], subtract: [], in: tracks,
                                    limit: 3, index: index, temperature: 0.5, variationSeed: 42)
        let b = SonicEngine.alchemy(add: [tracks[0]], subtract: [], in: tracks,
                                    limit: 3, index: index, temperature: 0.5, variationSeed: 42)
        XCTAssertEqual(a.map(\.track.id), b.map(\.track.id), "zelfde seed → zelfde mix")
        XCTAssertFalse(a.isEmpty)
    }

    /// Gap B: waypoint-interpolatie levert een monotone gradiënt — de cosinus
    /// met het doel mag over het pad niet dalen (de greedy walk kon afdrijven
    /// door te vroeg richting doel te springen).
    func testEmbeddingPathProgressesMonotonically() throws {
        func vec(_ t: Double) -> [Float] {
            var v = [Float](repeating: 0, count: 8)
            v[0] = Float(cos(t * .pi / 2))
            v[1] = Float(sin(t * .pi / 2))
            return v
        }
        var tracks = [track("from", vec(0)), track("to", vec(1))]
        for (i, t) in [0.2, 0.35, 0.5, 0.65, 0.8, 0.1, 0.9, 0.45].enumerated() {
            tracks.append(track("c\(i)", vec(t)))
        }
        let index = try XCTUnwrap(VectorIndex(tracks: tracks))
        let path = SongPaths.find(from: tracks[0], to: tracks[1], library: tracks,
                                  maxSteps: 6, index: index)
        XCTAssertEqual(path.first?.track.id, "from")
        XCTAssertEqual(path.last?.track.id, "to")
        let toV = try XCTUnwrap(index.embedding(forId: "to"))
        var prev = -1.0
        for s in path {
            let v = try XCTUnwrap(index.embedding(forId: s.track.id))
            let cos = Double(zip(v, toV).reduce(0) { $0 + $1.0 * $1.1 })
            XCTAssertGreaterThanOrEqual(cos + 1e-6, prev, "pad drijft af bij \(s.track.id)")
            prev = cos
        }
    }

    func testFallsBackWithoutIndex() {
        let tracks = lib()
        // No index -> rule-based path still returns results (all same camelot/bpm here).
        let hits = SonicEngine.similar(to: tracks[0], in: tracks, limit: 2)
        XCTAssertFalse(hits.isEmpty)
    }
}
