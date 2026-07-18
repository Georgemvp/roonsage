@testable import AnalyzerCore
import XCTest

/// The walk's per-file decision (`LibraryWalker.decide`). This is where the
/// 2026-07-17 re-analysis stagnation lived: the skip-check resolved on
/// (file_path, file_mtime) while the upsert conflicts on `match_key`, so two
/// files sharing one key each missed the other's row, re-analysed, and
/// overwrote it in turn — 130+ analyses per 5 minutes at zero net progress.
final class LibraryWalkerDecisionTests: XCTestCase {

    private typealias Row = (model: String?, filePath: String?, fileMtime: Double)
    private let model = "clap-v3"

    func testUnknownTrackIsAnalysedInFull() {
        XCTAssertEqual(LibraryWalker.decide(row: nil, path: "/m/new.flac", mtime: 100, currentModel: model),
                       .analyze(.full))
    }

    func testUnchangedFileWithCurrentModelIsSkipped() {
        let row: Row = (model, "/m/a.flac", 100)
        XCTAssertEqual(LibraryWalker.decide(row: row, path: "/m/a.flac", mtime: 100, currentModel: model),
                       .skip)
    }

    /// The regression that mattered: a DIFFERENT file resolving to the same
    /// match_key must NOT trigger a re-analysis, or the two overwrite each other
    /// on every pass and the walk never advances.
    func testTwinFileSharingTheKeyIsSkippedNotReanalysed() {
        let row: Row = (model, "/m/24bit.flac", 100)   // the 24bit version owns the row
        XCTAssertEqual(LibraryWalker.decide(row: row, path: "/m/16bit.flac", mtime: 999, currentModel: model),
                       .skip, "a twin's differing path+mtime is not a change — re-analysing it ping-pongs forever")
    }

    /// …while a real edit to the file that OWNS the row still forces a full pass.
    func testOwningFileWithChangedMtimeIsReanalysed() {
        let row: Row = (model, "/m/a.flac", 100)
        XCTAssertEqual(LibraryWalker.decide(row: row, path: "/m/a.flac", mtime: 5000, currentModel: model),
                       .analyze(.full))
    }

    /// Sub-second mtimes don't round-trip bit-stable through
    /// Date.timeIntervalSince1970; a few ULPs of drift is not an edit.
    func testSubSecondMtimeDriftIsNotAnEdit() {
        let stored = 1_780_616_819.057
        let row: Row = (model, "/m/a.flac", stored)
        XCTAssertEqual(LibraryWalker.decide(row: row, path: "/m/a.flac",
                                            mtime: stored.nextUp.nextUp.nextUp, currentModel: model),
                       .skip)
    }

    /// "Heranalyseer alles" parks a negative mtime — the explicit full-redo
    /// signal, which must win over every skip branch (the user's requirement is
    /// full-track re-analysis, not an embedding-only touch-up).
    func testReanalysisSentinelForcesFullEvenWithCurrentModel() {
        let row: Row = (model, "/m/a.flac", -1)
        XCTAssertEqual(LibraryWalker.decide(row: row, path: "/m/a.flac", mtime: 100, currentModel: model),
                       .analyze(.full))
    }

    func testStaleModelGetsEmbeddingOnlyPass() {
        let row: Row = ("clap-v2", "/m/a.flac", 100)
        XCTAssertEqual(LibraryWalker.decide(row: row, path: "/m/a.flac", mtime: 100, currentModel: model),
                       .analyze(.embeddingOnly), "scalars stand; only the embedding is stale")
    }

    func testMissingModelGetsEmbeddingOnlyPass() {
        let row: Row = (nil, "/m/a.flac", 100)
        XCTAssertEqual(LibraryWalker.decide(row: row, path: "/m/a.flac", mtime: 100, currentModel: model),
                       .analyze(.embeddingOnly))
    }

    /// Without CLAP loaded there is nothing left to add to an existing row —
    /// re-running scalars would be the old "full pass on every walk" behaviour.
    func testWithoutClapAnExistingRowIsSkipped() {
        let row: Row = (nil, "/m/a.flac", 100)
        XCTAssertEqual(LibraryWalker.decide(row: row, path: "/m/a.flac", mtime: 100, currentModel: nil),
                       .skip)
        XCTAssertEqual(LibraryWalker.decide(row: nil, path: "/m/a.flac", mtime: 100, currentModel: nil),
                       .analyze(.full), "but an unknown file is still analysed")
    }
}
