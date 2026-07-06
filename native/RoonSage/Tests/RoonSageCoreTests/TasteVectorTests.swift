import Foundation
import XCTest
@testable import RoonSageCore

/// Track E5 — the recency-weighted taste centroid over CLAP embeddings. Guards
/// the allocation-lean rewrite (needed-only embedding lookups + in-place vsma).
final class TasteVectorTests: XCTestCase {
    private func track(_ id: String, _ emb: [Float]) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(
            id: id, title: id, artist: "A", album: "Al", imageKey: nil, matchKey: id,
            bpm: 120, camelot: "8B", energy: 0.5, tags: [], embedding: emb)
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    func testTasteLeansTowardHeavilyPlayed() throws {
        let idx = try XCTUnwrap(VectorIndex(tracks: [
            track("a", [1, 0, 0, 0]), track("b", [0, 1, 0, 0]), track("c", [0, 0, 1, 0]),
        ]))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let iso = ISO8601DateFormatter().string(from: now)
        let taste = try XCTUnwrap(TasteVector.compute(
            stats: [(matchKey: "a", count: 100, lastPlayed: iso)],
            likedKeys: [], index: idx, now: now))
        XCTAssertGreaterThan(dot(taste, [1, 0, 0, 0]), dot(taste, [0, 1, 0, 0]),
                             "taste should lean toward the heavily-played track a")
    }

    func testLikesContributeWithoutPlays() throws {
        let idx = try XCTUnwrap(VectorIndex(tracks: [
            track("a", [1, 0, 0, 0]), track("b", [0, 1, 0, 0]), track("c", [0, 0, 1, 0]),
        ]))
        let taste = try XCTUnwrap(TasteVector.compute(
            stats: [], likedKeys: ["b"], index: idx, now: Date()))
        XCTAssertGreaterThan(dot(taste, [0, 1, 0, 0]), dot(taste, [1, 0, 0, 0]),
                             "an explicit like should steer taste toward b")
    }

    func testNilWithoutHistory() throws {
        let idx = try XCTUnwrap(VectorIndex(tracks: [
            track("a", [1, 0, 0, 0]), track("b", [0, 1, 0, 0]),
        ]))
        XCTAssertNil(TasteVector.compute(stats: [], likedKeys: [], index: idx, now: Date()),
                     "no plays and no likes -> no taste vector")
    }
}
