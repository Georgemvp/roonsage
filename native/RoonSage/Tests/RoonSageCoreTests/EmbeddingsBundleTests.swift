import AnalyzerCore
import AudioAnalysis
import Foundation
@testable import RoonSageCore
import XCTest

/// Track E5c — the binary `/embeddings` bundle round-trips from the analyzer's
/// FeatureStore (encode) to the app's DatabaseManager (decode + attach).
final class EmbeddingsBundleTests: XCTestCase {
    private var dir: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rs-emb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try DatabaseManager(url: dir.appendingPathComponent("library.db"))
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: dir)
    }

    func testEmbeddingsBlobRoundTripsAnalyzerToClient() async throws {
        let key = TrackIdentity.matchKey(artist: "Artist", album: "Album", title: "Title")
        let emb: [Float] = (0..<512).map { Float($0) / 512.0 - 0.5 }

        // --- analyzer side: store an embedding, build the binary bundle ---
        let fs = try FeatureStore(path: dir.appendingPathComponent("analyzer.db").path)
        try fs.upsert(TrackFeatureRow(
            matchKey: key, artist: "Artist", title: "Title", album: "Album", year: 2000,
            filePath: "/m/a.flac", fileMtime: 1, bpm: 120, bpmConfidence: 0.9,
            keyRoot: "C", keyMode: "major", camelot: "8B", energy: 0.5, duration: 200,
            tags: nil, analyzedAt: "t", embedding: emb, embeddingModel: "clap-v1", moods: nil))
        let blob = fs.embeddingsBlob()
        XCTAssertGreaterThan(blob.count, 13 + 512 * 4, "bundle must carry header + one vector")

        // --- client side: matching track + feature row, then apply ---
        try await db.upsertTracks([TrackRecord(
            id: "t1", title: "Title", artist: "Artist", album: "Album",
            albumKey: "ak", year: 2000, matchKey: key)])
        try await db.upsertAudioFeatures([DatabaseManager.AudioFeatureRow(
            matchKey: key, bpm: 120, camelot: "8B", keyRoot: "C", keyMode: "major",
            energy: 0.5, duration: 200, tags: nil, moods: nil)])

        let applied = try await db.applyEmbeddingsBlob(blob)
        XCTAssertEqual(applied, 1, "exactly one feature row should be updated")

        let sonic = try await db.sonicTracks(excludeLive: false)
        let track = try XCTUnwrap(sonic.first { $0.matchKey == key })
        let vec = try XCTUnwrap(track.embedding)
        XCTAssertEqual(vec.count, 512)
        XCTAssertEqual(vec.first!, emb.first!, accuracy: 1e-6)
        XCTAssertEqual(vec.last!, emb.last!, accuracy: 1e-6)
    }
}
