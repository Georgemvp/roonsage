@testable import AnalyzerCore
import Foundation
import XCTest

/// Zero-shot CLAP tagging: the pure scoring rule (z-floors, cap, sparse-honesty
/// top-up) and the FeatureStore resumability plumbing (tags_model stamping).
/// The CLAP model itself is exercised by the golden-vector CLAP tests.
final class ClapTaggerTests: XCTestCase {

    // MARK: scoring

    /// A term whose text prior is HIGH everywhere (mean 0.5) must lose from a
    /// term the track is *unusually* close to — the MoodCalibration argument.
    func testZScoreCancelsTextPrior() {
        // 4-dim toy space; embeddings are unit-ish (scoring only uses dots).
        let hot = ClapTagger.TermStats(tag: "hot-prior", embed: [1, 0, 0, 0], mean: 0.5, std: 0.1)
        let cold = ClapTagger.TermStats(tag: "cold-prior", embed: [0, 1, 0, 0], mean: 0.05, std: 0.1)
        // Track: dot(hot)=0.55 → z=0.5 (barely above ITS baseline);
        //        dot(cold)=0.35 → z=3.0 (very unusual for THIS term).
        let tags = ClapTagger.tags(for: [0.55, 0.35, 0, 0], terms: [hot, cold],
                                   zFloor: 1.0, zRelaxed: 0.5, maxTags: 6)
        XCTAssertEqual(tags.first, "cold-prior")
        XCTAssertFalse(tags.contains("hot-prior") && tags.first == "hot-prior",
                       "raw-cosine winner must not beat the z-score winner")
    }

    func testCapAndOrdering() {
        let terms = (0..<10).map { i in
            ClapTagger.TermStats(tag: "t\(i)", embed: [Float(i) * 0.1, 1, 0, 0], mean: 0, std: 0.1)
        }
        let tags = ClapTagger.tags(for: [1, 0, 0, 0], terms: terms,
                                   zFloor: 1.0, zRelaxed: 0.5, maxTags: 3)
        XCTAssertEqual(tags.count, 3, "capped at maxTags")
        XCTAssertEqual(tags, ["t9", "t8", "t7"], "best z first")
    }

    func testSparseTrackGetsAtMostTwoRelaxedTags() {
        // Nothing clears the strict floor; two clear the relaxed band.
        let terms = [
            ClapTagger.TermStats(tag: "a", embed: [1, 0, 0, 0], mean: 0.0, std: 1.0),   // z = 0.07
            ClapTagger.TermStats(tag: "b", embed: [0, 1, 0, 0], mean: 0.0, std: 0.1),   // z = 0.6
            ClapTagger.TermStats(tag: "c", embed: [0, 0, 1, 0], mean: 0.0, std: 0.1),   // z = 0.8
        ]
        let tags = ClapTagger.tags(for: [0.07, 0.06, 0.08, 0], terms: terms,
                                   zFloor: 1.0, zRelaxed: 0.5, maxTags: 6)
        XCTAssertEqual(Set(tags), Set(["b", "c"]), "top-up stops at two — no filler")
    }

    func testFlatTrackStaysUntagged() {
        let terms = [ClapTagger.TermStats(tag: "a", embed: [1, 0, 0, 0], mean: 0.5, std: 1.0)]
        let tags = ClapTagger.tags(for: [0.5, 0, 0, 0], terms: terms,
                                   zFloor: 1.0, zRelaxed: 0.5, maxTags: 6)
        XCTAssertTrue(tags.isEmpty, "a track unusual on nothing gets no tags (honest)")
    }

    func testVocabularyIsUniqueAndLowercase() {
        let tags = ClapTagVocabulary.terms.map(\.tag)
        XCTAssertEqual(tags.count, Set(tags).count, "duplicate vocabulary term")
        for t in tags {
            XCTAssertEqual(t, t.lowercased(), "vocabulary must be lowercase: \(t)")
            XCTAssertFalse(ClapTagVocabulary.terms.first { $0.tag == t }!.prompts.isEmpty)
        }
    }

    // MARK: FeatureStore plumbing

    private func makeStore() throws -> (FeatureStore, String) {
        let path = NSTemporaryDirectory() + "fs_claptag_\(UUID().uuidString).sqlite"
        return (try FeatureStore(path: path), path)
    }

    private func row(_ key: String, embedding: [Float]?, tags: String? = nil) -> TrackFeatureRow {
        TrackFeatureRow(
            matchKey: key, artist: "A", title: key, album: nil, year: nil,
            filePath: "/m/\(key).flac", fileMtime: 1, bpm: 120, bpmConfidence: 0.9,
            keyRoot: "C", keyMode: "major", camelot: "8B", energy: 0.5, duration: 200,
            tags: tags, analyzedAt: "2026-07-19T00:00:00Z",
            embedding: embedding, embeddingModel: embedding == nil ? nil : "clap-v3", moods: nil)
    }

    func testRowsNeedingClapTagsSelectsLegacyAndSkipsStamped() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try store.upsert(row("embedded-legacy", embedding: [1, 0], tags: #"["driving"]"#))
        try store.upsert(row("embedded-untagged", embedding: [0, 1]))
        try store.upsert(row("no-embedding", embedding: nil))

        var need = store.rowsNeedingClapTags(version: "v-test", limit: 10).map(\.matchKey)
        XCTAssertEqual(Set(need), Set(["embedded-legacy", "embedded-untagged"]),
                       "legacy Ollama tags count as needing a retag; unembedded rows never qualify")

        try store.setClapTags([("embedded-legacy", #"["techno"]"#)], model: "v-test")
        need = store.rowsNeedingClapTags(version: "v-test", limit: 10).map(\.matchKey)
        XCTAssertEqual(need, ["embedded-untagged"], "stamped row no longer selected")
        XCTAssertEqual(store.clapTaggedCount(version: "v-test"), 1)

        // A version bump re-selects everything embedded.
        need = store.rowsNeedingClapTags(version: "v-test-2", limit: 10).map(\.matchKey)
        XCTAssertEqual(Set(need), Set(["embedded-legacy", "embedded-untagged"]))
    }

    func testContentSignatureMovesOnRetag() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try store.upsert(row("x", embedding: [1, 0], tags: #"["driving"]"#))
        let before = store.contentSignature()
        try store.setClapTags([("x", #"["techno"]"#)], model: ClapTagVocabulary.version)
        XCTAssertNotEqual(store.contentSignature(), before,
                          "in-place retag must bump the corpus signature or clients never re-pull")
    }
}
