import Foundation
import GRDB
import XCTest
@testable import RoonSageCore

/// DatasetProducer — offline candidates from the distilled sidecar: gated on the
/// path, owned/disliked filtered out, capped, similarity in the 0.3…0.9 band.
final class DatasetProducerTests: XCTestCase {

    private func makeSidecar(_ rows: [(artist: String, album: String, fans: Int)]) throws -> String {
        let path = NSTemporaryDirectory() + "sidecar_prod_\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
                CREATE TABLE ds_candidates (
                    artist TEXT, album TEXT, year INTEGER,
                    genres TEXT, fans INTEGER, source TEXT
                )
            """)
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO ds_candidates (artist, album, year, genres, fans, source)
                    VALUES (?, ?, 2020, '["jazz"]', ?, 'deezer')
                """, arguments: [r.artist, r.album, r.fans])
            }
        }
        return path
    }

    private func context(sidecarPath: String?) -> ProducerContext {
        ProducerContext(musicBrainz: MusicBrainzDiscoveryClient.shared,
                        perProducerLimit: 3, datasetSidecarPath: sidecarPath)
    }

    func testGatingOnSidecarPath() {
        let producer = DatasetProducer()
        XCTAssertFalse(producer.isEnabled(context(sidecarPath: nil)))
        XCTAssertFalse(producer.isEnabled(context(sidecarPath: "/nonexistent/metadata.db")))
    }

    func testDiscoverFiltersOwnedAndDislikedAndCaps() async throws {
        let path = try makeSidecar([
            ("Jeff Lorber", "Galaxy", 90_000),
            ("Dave Koz", "Saxophonic", 80_000),
            ("Bob Moses", "Battle Lines", 70_000),      // disliked → dropped
            ("Boney James", "Solid", 60_000),
            ("Melody Gardot", "Currency of Man", 50_000),
            ("Jeff Lorber", "Galaxy", 90_000),          // duplicate → dropped
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let producer = DatasetProducer()
        let ctx = context(sidecarPath: path)
        XCTAssertTrue(producer.isEnabled(ctx))

        let seeds = DiscoverySeeds(
            dislikedArtists: ["Bob Moses"],
            libraryAlbumKeys: ["dave koz|saxophonic"])   // owned → dropped
        let out = await producer.discover(seeds: seeds, context: ctx)

        XCTAssertEqual(out.count, 3, "capped at perProducerLimit")
        let artists = Set(out.map(\.artist))
        XCTAssertFalse(artists.contains("Bob Moses"), "disliked artist must be filtered")
        XCTAssertFalse(out.contains { $0.artist == "Dave Koz" && $0.album == "Saxophonic" },
                       "owned album must be filtered")
        for c in out {
            XCTAssertEqual(c.kind, .album)
            XCTAssertEqual(c.producer, "dataset")
            let sim = try XCTUnwrap(c.similarity)
            XCTAssertGreaterThanOrEqual(sim, 0.3)
            XCTAssertLessThanOrEqual(sim, 0.9)
            XCTAssertEqual(c.genres, ["jazz"])
        }
    }

    func testMalformedSidecarYieldsNothing() async throws {
        // A database without ds_candidates: producer contributes nothing, no throw.
        let path = NSTemporaryDirectory() + "sidecar_bad_\(UUID().uuidString).sqlite"
        _ = try DatabaseQueue(path: path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let out = await DatasetProducer().discover(seeds: DiscoverySeeds(), context: context(sidecarPath: path))
        XCTAssertEqual(out.count, 0)
    }
}
