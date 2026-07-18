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

    /// Sub-second file mtimes don't round-trip bit-stable through Swift's
    /// Date.timeIntervalSince1970, so a fresh FileManager read drifts a few ULPs
    /// from the stored value. Exact float equality on file_mtime then misses and
    /// the file is fully re-analysed every walk (v3 stagnation, 2026-07-17). The
    /// skip/embedding sites must match within a sub-second tolerance instead.
    func testRowStateToleratesSubSecondMtimeDrift() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let stored = 1_780_616_819.057            // as written by the v3 analysis
        let fresh = stored.nextUp.nextUp.nextUp   // a fresh read, a few ULPs higher
        XCTAssertNotEqual(stored, fresh, "precondition: the two reads differ (float drift)")
        XCTAssertLessThan(abs(stored - fresh), 0.5, "precondition: drift is far below a real edit")

        try store.upsert(baseRow(path: "/m/d.flac", mtime: stored, embedding: [1, 2], model: "clap-v3", moods: nil))

        // The walk's skip-check reads `fresh` from disk — it must still recognise
        // the row as fully analysed rather than forcing mode .full.
        let st = store.rowState(path: "/m/d.flac", mtime: fresh)
        XCTAssertTrue(st.exists, "sub-second mtime drift must NOT force re-analysis")
        XCTAssertEqual(st.model, "clap-v3")
        XCTAssertTrue(store.isAnalyzed(path: "/m/d.flac", mtime: fresh), "isAnalyzed must tolerate the same drift")

        // An embedding-only re-pass must land on the same (drifted) row.
        try store.setEmbedding(path: "/m/d.flac", mtime: fresh, embedding: [7, 8], model: "clap-v3", moods: nil)
        let r = try XCTUnwrap(store.featureRow(path: "/m/d.flac", mtime: stored))
        XCTAssertEqual(r.embedding, [7, 8], "setEmbedding finds the drifted row and updates it")
    }

    /// Two DIFFERENT files that normalise to one match_key (24bit/16bit versions,
    /// live vs studio, album + compilation) share a single row, because match_key
    /// is the primary key. Keyed on (file_path, mtime) the walker misses that row
    /// for whichever file doesn't own it, re-analyses, and the upsert overwrites
    /// the other — the two ping-pong forever and the walk makes zero net progress
    /// (2026-07-17: 13.100 files over 5.743 keys, v3-count frozen). The skip-check
    /// must therefore resolve on match_key, the same key the upsert conflicts on.
    func testRowStateByMatchKeyFindsTwinFileRow() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // The 24bit version is analysed first and owns the row.
        try store.upsert(baseRow(path: "/m/24bit.flac", mtime: 1000,
                                 embedding: [1, 2], model: "clap-v3", moods: nil))

        // The walker now reaches the 16bit twin: different path, different mtime,
        // SAME match_key. The path-keyed check misses it (that is the bug)…
        XCTAssertFalse(store.rowState(path: "/m/16bit.flac", mtime: 2000).exists,
                       "precondition: the path-keyed check cannot see the twin's row")

        // …while the storage-keyed check finds it and reports who owns it.
        let st = try XCTUnwrap(store.rowState(matchKey: "artist\u{1f}title"),
                               "the row must be findable by the key the upsert conflicts on")
        XCTAssertEqual(st.model, "clap-v3", "current model ⇒ the walker skips instead of re-analysing")
        XCTAssertEqual(st.filePath, "/m/24bit.flac")
        XCTAssertEqual(st.fileMtime, 1000, accuracy: 0.001)

        // An embedding-only pass keyed on match_key lands on that same row.
        try store.setEmbedding(matchKey: "artist\u{1f}title", embedding: [7, 8], model: "clap-v3", moods: nil)
        let r = try XCTUnwrap(store.featureRow(path: "/m/24bit.flac", mtime: 1000))
        XCTAssertEqual(r.embedding, [7, 8])
        XCTAssertEqual(r.bpm, 120, accuracy: 0.001, "scalars preserved")

        XCTAssertNil(store.rowState(matchKey: "nobody\u{1f}nothing"), "unknown key ⇒ nil")
    }

    /// The re-analysis sentinel must stay VISIBLE to the storage-keyed lookup:
    /// the walker recognises `file_mtime < 0` as "re-analyse in full" rather than
    /// inferring it from a failed lookup (which is what let colliding files
    /// overwrite each other). Full-track re-analysis is the user's explicit
    /// requirement ("de analyse moet helemaal kloppen zoals bij audiomuse").
    func testMarkAllForReanalysisIsVisibleByMatchKey() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try store.upsert(baseRow(path: "/m/e.flac", mtime: 5000,
                                 embedding: [1, 2], model: "clap-v3", moods: nil))
        XCTAssertEqual(try store.markAllForReanalysis(), 1)

        let st = try XCTUnwrap(store.rowState(matchKey: "artist\u{1f}title"),
                               "the marked row must remain findable by match_key")
        XCTAssertLessThan(st.fileMtime, 0, "the negative sentinel is what forces mode .full")
        XCTAssertEqual(st.model, "clap-v3", "the model is untouched — only the mtime is the signal")
    }

    /// "Heranalyseer alles": the sentinel mtime makes every row look new
    /// (mode .full on the next walk), while the re-analysis upsert keeps
    /// enrichment — the ON CONFLICT clause never touches tags.
    func testMarkAllForReanalysis() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        var row = baseRow(path: "/m/c.flac", mtime: 3000, embedding: [1, 2], model: "clap-v2", moods: nil)
        row.tags = #"["rock"]"#
        try store.upsert(row)
        XCTAssertTrue(store.rowState(path: "/m/c.flac", mtime: 3000).exists)

        let marked = try store.markAllForReanalysis()
        XCTAssertEqual(marked, 1)
        XCTAssertFalse(store.rowState(path: "/m/c.flac", mtime: 3000).exists,
                       "sentinel mtime must force mode .full on the next walk")

        // The re-analysis upsert (tags: nil) must NOT wipe existing tags.
        try store.upsert(baseRow(path: "/m/c.flac", mtime: 3000, embedding: [3, 4], model: "clap-v3", moods: nil))
        let r = try XCTUnwrap(store.featureRow(path: "/m/c.flac", mtime: 3000))
        XCTAssertEqual(r.tags, #"["rock"]"#, "enrichment survives full re-analysis")
        XCTAssertEqual(r.embedding, [3, 4])
    }
}
