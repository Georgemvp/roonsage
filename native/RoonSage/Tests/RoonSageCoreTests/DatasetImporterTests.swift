import AnalyzerCore
import AudioAnalysis
import Foundation
import GRDB
import XCTest

/// Dataset-sidecar import (MusicMoveArr): pass A keys raw sidecar rows with the
/// real TrackIdentity scheme, pass B copies ISRC/MBID/Deezer metrics onto
/// track_features — resumable, never overwriting existing values with NULL.
final class DatasetImporterTests: XCTestCase {

    private func makeStore() throws -> (FeatureStore, String) {
        let path = NSTemporaryDirectory() + "fs_dataset_\(UUID().uuidString).sqlite"
        return (try FeatureStore(path: path), path)
    }

    private struct DS {
        var source: String
        var artist: String
        var title: String
        var album: String?
        var isrc: String?
        var mbid: String?
        var bpm: Double?
        var gain: Double?
        var rank: Int?
        init(source: String, artist: String, title: String, album: String? = nil,
             isrc: String? = nil, mbid: String? = nil, bpm: Double? = nil,
             gain: Double? = nil, rank: Int? = nil) {
            self.source = source; self.artist = artist; self.title = title; self.album = album
            self.isrc = isrc; self.mbid = mbid; self.bpm = bpm; self.gain = gain; self.rank = rank
        }
    }

    private func makeSidecar(_ rows: [DS]) throws -> (DatabaseQueue, String) {
        let path = NSTemporaryDirectory() + "sidecar_\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
                CREATE TABLE ds_tracks (
                    source TEXT, artist TEXT, title TEXT, album TEXT,
                    isrc TEXT, recording_mbid TEXT,
                    duration REAL, bpm REAL, gain REAL, rank INTEGER,
                    match_key TEXT
                )
            """)
            for r in rows {
                let args: [DatabaseValueConvertible?] = [r.source, r.artist, r.title, r.album,
                                                         r.isrc, r.mbid, r.bpm, r.gain, r.rank]
                try db.execute(sql: """
                    INSERT INTO ds_tracks (source, artist, title, album, isrc, recording_mbid, bpm, gain, rank)
                    VALUES (?,?,?,?,?,?,?,?,?)
                """, arguments: StatementArguments(args))
            }
        }
        return (q, path)
    }

    private func storeRow(artist: String, title: String) -> TrackFeatureRow {
        TrackFeatureRow(
            matchKey: TrackIdentity.matchKey(artist: artist, album: "Album", title: title),
            artist: artist, title: title, album: "Album", year: 2020,
            filePath: "/m/\(title).flac", fileMtime: 1000, bpm: 120, bpmConfidence: 0.9,
            keyRoot: "C", keyMode: "major", camelot: "8B", energy: 0.5, duration: 200,
            tags: nil, analyzedAt: "2026-07-08T00:00:00Z")
    }

    private func exportedObjects(_ store: FeatureStore) throws -> [String: [String: Any]] {
        let arr = try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportJSON()) as? [[String: Any]])
        var byArtist: [String: [String: Any]] = [:]
        for o in arr { byArtist[o["artist"] as? String ?? ""] = o }
        return byArtist
    }

    func testImportMatchesIdentityAndMetrics() async throws {
        let (store, storePath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: storePath) }

        try store.upsert(storeRow(artist: "Daft Punk", title: "One More Time"))
        try store.upsert(storeRow(artist: "Bob Moses", title: "Here We Are"))
        let preset = storeRow(artist: "Bob Moses", title: "Here We Are")
        try store.setPopularity(matchKey: preset.matchKey, popularity: 500, checkedAt: "2026-07-01T00:00:00Z")
        try store.upsert(storeRow(artist: "Nobody", title: "No Match"))

        // Sidecar carries RAW strings — the remaster suffix must normalise away.
        let (_, sidecarPath) = try makeSidecar([
            DS(source: "deezer", artist: "Daft Punk", title: "One More Time (2001 Remaster)",
               isrc: "GBDUW0000059", bpm: 123.0, gain: -7.1, rank: 900_000),
            DS(source: "deezer", artist: "Daft Punk", title: "One More Time",
               isrc: "GBDUW0000OLD", bpm: 118.0, rank: 100),   // lower rank must lose
            DS(source: "musicbrainz", artist: "Daft Punk", title: "One More Time",
               mbid: "mbid-daft-1"),
            DS(source: "tidal", artist: "Bob Moses", title: "Here We Are",
               isrc: "USUG11600976", rank: 50),
        ])
        defer { try? FileManager.default.removeItem(atPath: sidecarPath) }

        let importer = try DatasetImporter(store: store, sidecarPath: sidecarPath, batch: 2)
        try await importer.run { _ in }

        let byArtist = try exportedObjects(store)
        let daft = try XCTUnwrap(byArtist["Daft Punk"])
        XCTAssertEqual(daft["isrc"] as? String, "GBDUW0000059", "highest-ranked Deezer row's ISRC wins")
        XCTAssertEqual(daft["recording_mbid"] as? String, "mbid-daft-1")
        XCTAssertEqual(daft["popularity"] as? Int, 900_000, "dump rank fills empty popularity")

        let bob = try XCTUnwrap(byArtist["Bob Moses"])
        XCTAssertEqual(bob["isrc"] as? String, "USUG11600976", "non-Deezer ISRC still lands")
        XCTAssertEqual(bob["popularity"] as? Int, 500, "API-fetched popularity must NOT be overwritten by the dump")

        let nobody = try XCTUnwrap(byArtist["Nobody"])
        XCTAssertNil(nobody["isrc"], "unmatched row gets no identity")
        XCTAssertEqual(store.datasetCheckedCount(), 3, "every row is stamped checked, incl. no-match")
        XCTAssertEqual(store.isrcCount(), 2)
    }

    func testImportIsResumableAndIdempotent() async throws {
        let (store, storePath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: storePath) }
        try store.upsert(storeRow(artist: "Daft Punk", title: "One More Time"))

        let (sidecar, sidecarPath) = try makeSidecar([
            DS(source: "deezer", artist: "Daft Punk", title: "One More Time",
               isrc: "GBDUW0000059", bpm: 123.0, rank: 900_000),
        ])
        defer { try? FileManager.default.removeItem(atPath: sidecarPath) }

        try await DatasetImporter(store: store, sidecarPath: sidecarPath).run { _ in }
        let keyed = try await sidecar.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(match_key) FROM ds_tracks") ?? 0
        }
        XCTAssertEqual(keyed, 1, "pass A stamps every sidecar row")

        // Second run: nothing left to key or check — and values stay put.
        try await DatasetImporter(store: store, sidecarPath: sidecarPath).run { _ in }
        XCTAssertEqual(store.datasetCheckedCount(), 1)
        XCTAssertEqual(store.isrcCount(), 1)
    }

    func testMissingSidecarThrows() throws {
        let (store, storePath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: storePath) }
        XCTAssertThrowsError(try DatasetImporter(store: store, sidecarPath: "/nonexistent/metadata.db"))
    }
}
