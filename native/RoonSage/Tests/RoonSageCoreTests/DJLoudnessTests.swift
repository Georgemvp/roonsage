import AudioAnalysis
@testable import RoonSageCore
import XCTest

/// Feature 3 — loudness-aware DJ sequencing. Loudness is an EXTRA factor next to
/// BPM/Camelot/energy: it nudges the greedy walk away from big perceived-level
/// jumps between consecutive tracks, and is fully skipped (identical behaviour)
/// when a track has no loudness value.
final class DJLoudnessTests: XCTestCase {

    private func cand(_ id: String, loud: Double?) -> DatabaseManager.DJCandidate {
        // Identical bpm/energy/camelot + distinct artists, so loudness is the only
        // differentiator between candidates at each step (energy 0.6 == the flat
        // curve's target, bpm 120 == the flat BPM target → zero bpm/energy penalty).
        DatabaseManager.DJCandidate(
            id: id, title: id, artist: id, album: nil, bpm: 120, camelot: "8A",
            energy: 0.6, loudness: loud, tags: nil, imageKey: nil)
    }

    func testLoudnessSmoothsLevelJumps() {
        // Input order deliberately puts the big jump (C, −20) before the gentle one
        // (B, −11). With loudness active the sequencer should pick B second (closer
        // to A's −10) and defer C — reordering the input.
        let set = DJSetBuilder.build(
            candidates: [cand("A", loud: -10), cand("C", loud: -20), cand("B", loud: -11)],
            count: 3, startBPM: 120, endBPM: 120, curve: .flat)
        XCTAssertEqual(set.map(\.id), ["A", "B", "C"], "the gentler level step is preferred next")
    }

    func testFallbackWhenLoudnessMissing() {
        // Same shape but no loudness data → loudness is ignored and the order falls
        // back to the pre-F3 behaviour (input order, everything else being equal).
        let set = DJSetBuilder.build(
            candidates: [cand("A", loud: nil), cand("C", loud: nil), cand("B", loud: nil)],
            count: 3, startBPM: 120, endBPM: 120, curve: .flat)
        XCTAssertEqual(set.map(\.id), ["A", "C", "B"], "no loudness → unchanged behaviour")
    }

    func testMixedLoudnessDoesNotCrashAndKeepsAll() {
        // One track lacks loudness — the penalty is skipped for pairs involving it,
        // never a crash, and the full set is still returned.
        let set = DJSetBuilder.build(
            candidates: [cand("A", loud: -10), cand("B", loud: nil), cand("C", loud: -12)],
            count: 3, startBPM: 120, endBPM: 120, curve: .flat)
        XCTAssertEqual(Set(set.map(\.id)), ["A", "B", "C"])
        XCTAssertEqual(set.count, 3)
    }
}

/// The K-weighted loudness meter itself.
final class LoudnessAnalyzerTests: XCTestCase {

    private func sine(freq: Double, amp: Float, seconds: Double, sr: Double) -> [Float] {
        let n = Int(seconds * sr)
        return (0..<n).map { amp * Float(sin(2 * Double.pi * freq * Double($0) / sr)) }
    }

    func testLouderSignalMeasuresHigherLUFS() {
        let sr = 22050.0
        let loud = LoudnessAnalyzer.integratedLUFS(sine(freq: 1000, amp: 0.5, seconds: 1, sr: sr), sampleRate: sr)
        let quiet = LoudnessAnalyzer.integratedLUFS(sine(freq: 1000, amp: 0.1, seconds: 1, sr: sr), sampleRate: sr)
        XCTAssertNotNil(loud); XCTAssertNotNil(quiet)
        XCTAssertGreaterThan(loud!, quiet!, "a louder signal yields a higher (less negative) LUFS")
    }

    func testSilenceIsNil() {
        XCTAssertNil(LoudnessAnalyzer.integratedLUFS([Float](repeating: 0, count: 4096), sampleRate: 22050))
    }

    func testEmptyIsNil() {
        XCTAssertNil(LoudnessAnalyzer.integratedLUFS([], sampleRate: 22050))
    }
}
