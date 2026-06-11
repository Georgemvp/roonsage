import AudioAnalysis
import Foundation
import XCTest

/// Synthetic-signal tests for the DSP accuracy work (E2). Real-world audio is
/// messier, but these prove the core behaviour: BPM locks onto the right octave
/// (not half/double), and the key detector picks the right tonic + mode on a
/// clean tone cluster.
final class AudioAccuracyTests: XCTestCase {

    private let sr = 22050.0

    /// A click track: short impulses every `period` seconds for `seconds`.
    private func clickTrack(bpm: Double, seconds: Double) -> [Float] {
        var s = [Float](repeating: 0, count: Int(sr * seconds))
        let stride = Int(sr * 60.0 / bpm)
        var i = 0
        while i < s.count {
            for k in 0..<64 where i + k < s.count { s[i + k] = 1.0 - Float(k) / 64.0 } // brief decaying click
            i += stride
        }
        return s
    }

    /// Sustained sum of sine tones at the given frequencies.
    private func tones(_ freqs: [Double], seconds: Double) -> [Float] {
        let n = Int(sr * seconds)
        var s = [Float](repeating: 0, count: n)
        for f in freqs {
            let w = 2.0 * Double.pi * f / sr
            for i in 0..<n { s[i] += Float(sin(w * Double(i))) }
        }
        let peak = s.map { abs($0) }.max() ?? 1
        if peak > 0 { for i in 0..<n { s[i] /= peak } }
        return s
    }

    func testBPMLocksOntoCorrectOctave() {
        let (bpm, _) = TempoAnalyzer.bpm(clickTrack(bpm: 120, seconds: 12), sampleRate: sr)
        // Must be ~120, NOT the 60 or 240 octave — the comb filter's job.
        XCTAssertEqual(bpm, 120, accuracy: 6, "got \(bpm)")
    }

    func testBPMSlowTempoNotDoubled() {
        let (bpm, _) = TempoAnalyzer.bpm(clickTrack(bpm: 90, seconds: 14), sampleRate: sr)
        XCTAssertEqual(bpm, 90, accuracy: 6, "got \(bpm)")
    }

    func testKeyDetectsCMajorScale() {
        // Full C major scale, tonic emphasised (doubled) for a clear tonal centre.
        // A bare triad is genuinely ambiguous; a scale gives the K-K profiles signal.
        let key = KeyAnalyzer.detect(
            tones([261.63, 261.63, 293.66, 329.63, 349.23, 392.00, 440.00, 493.88], seconds: 6),
            sampleRate: sr)
        XCTAssertEqual(key.rootIndex, 0, "root \(key.rootIndex) mode \(key.mode)")
        XCTAssertEqual(key.mode, "major")
    }

    func testKeyDetectsCMinorScale() {
        // C natural minor (Eb/Ab/Bb distinguish the mode), tonic emphasised.
        let key = KeyAnalyzer.detect(
            tones([261.63, 261.63, 293.66, 311.13, 349.23, 392.00, 415.30, 466.16], seconds: 6),
            sampleRate: sr)
        XCTAssertEqual(key.rootIndex, 0, "root \(key.rootIndex) mode \(key.mode)")
        XCTAssertEqual(key.mode, "minor")
    }
}
