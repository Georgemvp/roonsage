import AnalyzerCore
import Foundation
import XCTest

/// Track E5c — persistence of the sonic embedding: BLOB round-trip, moods JSON,
/// and the model-version gating that drives embedding-only re-analysis.
final class FeatureStoreEmbeddingTests: XCTestCase {

    private func makeStore() throws -> (FeatureStore, String) {
        let path = NSTemporaryDirectory() + "fs_embed_\(UUID().uuidString).sqlite"
        return (try FeatureStore(path: path), path)
    }

    private func baseRow(path: String, mtime: Double,
                         embedding: [Float]?, model: String?, moods: String?) -> TrackFeatureRow {
        TrackFeatureRow(
            matchKey: "artist\u{1f}title", artist: "Artist", title: "Title", album: "Album", year: 2020,
            filePath: path, fileMtime: mtime, bpm: 120, bpmConfidence: 0.9,
            keyRoot: "C", keyMode: "major", camelot: "8B", energy: 0.5, duration: 200,
            tags: nil, analyzedAt: "2026-06-14T00:00:00Z",
            embedding: embedding, embeddingModel: model, moods: moods)
    }

    func testEmbeddingBlobRoundTrip() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let emb: [Float] = [0.1, -0.2, 0.3, 0.4, -0.5]
        let moods = #"{"happy":0.7,"sad":0.1}"#
        try store.upsert(baseRow(path: "/m/a.flac", mtime: 1000, embedding: emb, model: "clap-v1", moods: moods))

        let r = try XCTUnwrap(store.featureRow(path: "/m/a.flac", mtime: 1000))
        XCTAssertEqual(r.embedding, emb, "embedding BLOB must round-trip exactly")
        XCTAssertEqual(r.embeddingModel, "clap-v1")
        XCTAssertEqual(r.moods, moods)
        XCTAssertEqual(r.bpm, 120, accuracy: 0.001)
    }

    func testRowStateGating() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // scalars only (no embedding yet)
        try store.upsert(baseRow(path: "/m/b.flac", mtime: 2000, embedding: nil, model: nil, moods: nil))
        var st = store.rowState(path: "/m/b.flac", mtime: 2000)
        XCTAssertTrue(st.exists)
        XCTAssertNil(st.model, "no embedding model yet")

        // embedding-only pass fills it in without touching scalars
        try store.setEmbedding(path: "/m/b.flac", mtime: 2000,
                               embedding: [1, 2, 3], model: "clap-v1", moods: #"{"party":0.4}"#)
        st = store.rowState(path: "/m/b.flac", mtime: 2000)
        XCTAssertEqual(st.model, "clap-v1")
        let r = try XCTUnwrap(store.featureRow(path: "/m/b.flac", mtime: 2000))
        XCTAssertEqual(r.embedding, [1, 2, 3])
        XCTAssertEqual(r.bpm, 120, accuracy: 0.001, "scalars preserved through setEmbedding")
        XCTAssertEqual(r.moods, #"{"party":0.4}"#)

        // missing row -> not fully analyzed
        let none = store.rowState(path: "/m/missing.flac", mtime: 1)
        XCTAssertFalse(none.exists)
    }
}
