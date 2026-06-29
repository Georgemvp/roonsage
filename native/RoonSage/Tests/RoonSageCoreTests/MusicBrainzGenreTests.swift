import AnalyzerCore
import Foundation
import XCTest
@testable import RoonSageCore

/// MusicBrainz genre enrichment: analyzer-side storage/export (FeatureStore) and
/// library-side propagation + hierarchical filtering (DatabaseManager).
final class MusicBrainzGenreTests: XCTestCase {

    // MARK: - Analyzer side (FeatureStore)

    private func makeStore() throws -> (FeatureStore, String) {
        let path = NSTemporaryDirectory() + "mb_\(UUID().uuidString).sqlite"
        return (try FeatureStore(path: path), path)
    }

    private func row(_ mk: String, artist: String, album: String, path: String) -> TrackFeatureRow {
        TrackFeatureRow(
            matchKey: mk, artist: artist, title: "T-\(mk)", album: album, year: 2001,
            filePath: path, fileMtime: 1, bpm: 120, bpmConfidence: 0.9,
            keyRoot: "C", keyMode: "major", camelot: "8B", energy: 0.5, duration: 200,
            tags: nil, analyzedAt: "2026-06-27T00:00:00Z")
    }

    func testAlbumGroupingAndEnrichmentIsResumable() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try store.upsertBatch([
            row("a\u{1f}t1", artist: "Artist", album: "Blue", path: "/m/1.flac"),
            row("a\u{1f}t2", artist: "Artist", album: "Blue", path: "/m/2.flac"),
            row("a\u{1f}t3", artist: "Other", album: "Red", path: "/m/3.flac"),
        ])

        let albums = store.albumsNeedingMBGenres(limit: 10)
        XCTAssertEqual(albums.count, 2)
        let blue = try XCTUnwrap(albums.first { $0.album == "Blue" })
        XCTAssertEqual(Set(blue.matchKeys), ["a\u{1f}t1", "a\u{1f}t2"])

        try store.setMBGenres(matchKeys: blue.matchKeys, genres: ["blues rock", "rock"], checkedAt: "2026-06-27T00:00:00Z")
        // Blue is done; only Red remains → resumable.
        XCTAssertEqual(store.albumsNeedingMBGenres(limit: 10).map(\.album), ["Red"])
        XCTAssertEqual(store.mbEnrichedCount(), 2)

        // A fruitless lookup still marks the row checked (no infinite retry).
        try store.setMBGenres(matchKeys: ["a\u{1f}t3"], genres: [], checkedAt: "2026-06-27T00:00:00Z")
        XCTAssertTrue(store.albumsNeedingMBGenres(limit: 10).isEmpty)
        XCTAssertEqual(store.mbEnrichedCount(), 2)   // t3 checked but genre-less
        XCTAssertEqual(store.mbCheckedCount(), 3)
    }

    func testExportIncludesMBGenresAndSignatureTracksProgress() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try store.upsert(row("a\u{1f}t1", artist: "Artist", album: "Blue", path: "/m/1.flac"))
        let before = store.contentSignature()

        try store.setMBGenres(matchKeys: ["a\u{1f}t1"], genres: ["jazz", "bebop"], checkedAt: "2026-06-27T00:00:00Z")
        XCTAssertNotEqual(store.contentSignature(), before, "MB enrichment must change the signature so clients re-sync")

        let json = store.exportJSON()
        let arr = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        let obj = try XCTUnwrap(arr.first)
        XCTAssertEqual(obj["mb_genres"] as? [String], ["jazz", "bebop"])
    }

    func testTaxonomyParentResolutionIsBounded() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try store.upsert(row("a\u{1f}t1", artist: "Artist", album: "Blue", path: "/m/1.flac"))
        try store.setMBGenres(matchKeys: ["a\u{1f}t1"], genres: ["blues rock"], checkedAt: "x")

        XCTAssertEqual(store.genresInUse(), ["blues rock"])
        XCTAssertEqual(store.unresolvedParentGenres(["blues rock"]), ["blues rock"])

        try store.setGenreParent(genre: "blues rock", parent: "rock")
        // Resolved genres aren't re-queried.
        XCTAssertTrue(store.unresolvedParentGenres(["blues rock"]).isEmpty)

        let tax = try XCTUnwrap(JSONSerialization.jsonObject(with: store.taxonomyJSON()) as? [[String: Any]])
        XCTAssertEqual(tax.first?["genre"] as? String, "blues rock")
        XCTAssertEqual(tax.first?["parent"] as? String, "rock")
    }

    func testTaxonomyCompletenessFlagGatesVocabularyRefetch() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Fresh store: vocabulary has never been fully fetched.
        XCTAssertFalse(store.taxonomyComplete())
        try store.markTaxonomyComplete()
        XCTAssertTrue(store.taxonomyComplete(), "flag must persist so a partial fetch isn't taken as complete")
    }

    func testResetProvisionalRootsHealsFalseRoots() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Simulate a prior INCOMPLETE run that stamped a real subgenre as a root
        // (its parent lived on an unfetched page) and a genuine root.
        try store.setGenreParent(genre: "blues rock", parent: "")   // false root
        try store.setGenreParent(genre: "jazz", parent: "")         // would-be real root
        XCTAssertTrue(store.unresolvedParentGenres(["blues rock", "jazz"]).isEmpty,
                      "parent='' counts as resolved, so these are never re-queried")

        // Healing reset: both drop back to unresolved so the next pass re-resolves
        // them against the now-complete vocabulary.
        try store.resetProvisionalRoots()
        XCTAssertEqual(Set(store.unresolvedParentGenres(["blues rock", "jazz"])), ["blues rock", "jazz"])

        // A genuinely-resolved parent relation is untouched by the reset.
        try store.setGenreParent(genre: "blues rock", parent: "rock")
        try store.resetProvisionalRoots()
        XCTAssertTrue(store.unresolvedParentGenres(["blues rock"]).isEmpty)
    }

    // MARK: - Library side (DatabaseManager)

    private func makeDB() throws -> (DatabaseManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mb-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("library.db")
        return (try DatabaseManager(url: url), url)
    }

    private func track(_ id: String, _ title: String, _ artist: String, mk: String) -> TrackRecord {
        TrackRecord(id: id, title: title, artist: artist, album: "Album", albumKey: "ak", year: 2001, matchKey: mk)
    }

    func testParentGenreFilterExpandsToSubgenres() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await db.upsertTracks([
            track("t1", "Blues Track", "Artist", mk: "artist\u{1f}blues track"),
            track("t2", "Pop Track", "Artist", mk: "artist\u{1f}pop track"),
        ])
        try await db.upsertMBGenres([
            (matchKey: "artist\u{1f}blues track", genres: ["Blues Rock"]),
            (matchKey: "artist\u{1f}pop track", genres: ["Synthpop"]),
        ])
        try await db.upsertGenreTaxonomy([
            (genre: "blues rock", parent: "rock", mbid: nil),
            (genre: "rock", parent: nil, mbid: nil),
            (genre: "synthpop", parent: "pop", mbid: nil),
        ])

        // Filtering on the PARENT "rock" must surface the "blues rock" track via
        // descendant expansion, and must NOT surface the synthpop track.
        var opts = DatabaseManager.FilterOptions()
        opts.genres = ["Rock"]
        let rock = try await db.filterTracks(options: opts)
        XCTAssertEqual(rock.map(\.id), ["t1"])

        // A direct subgenre filter still works (flat match).
        opts.genres = ["synthpop"]
        let synth = try await db.filterTracks(options: opts)
        XCTAssertEqual(synth.map(\.id), ["t2"])
    }

    func testGenreTreeGroupsInUseGenres() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.upsertTracks([track("t1", "X", "A", mk: "a\u{1f}x")])
        try await db.upsertMBGenres([(matchKey: "a\u{1f}x", genres: ["blues rock", "rock"])])
        try await db.upsertGenreTaxonomy([
            (genre: "blues rock", parent: "rock", mbid: nil),
            (genre: "rock", parent: nil, mbid: nil),
        ])
        let tree = try await db.genreTree()
        XCTAssertEqual(tree.map(\.genre), ["rock"])
        XCTAssertEqual(tree.first?.subgenres, ["blues rock"])
    }

    func testExpandGenresDegradesToFlatWithoutTaxonomy() async throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.upsertTracks([track("t1", "X", "A", mk: "a\u{1f}x")])
        try await db.upsertMBGenres([(matchKey: "a\u{1f}x", genres: ["jazz"])])

        var opts = DatabaseManager.FilterOptions()
        opts.genres = ["jazz"]
        let hit = try await db.filterTracks(options: opts)
        XCTAssertEqual(hit.map(\.id), ["t1"])
    }
}
