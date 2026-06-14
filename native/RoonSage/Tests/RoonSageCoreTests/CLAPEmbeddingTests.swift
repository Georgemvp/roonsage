@testable import AudioAnalysis
import CoreML
import Foundation
import XCTest

/// Golden-reference tests for the native CLAP front-end (Track E, Step 1).
///
/// They prove the Swift mel front-end matches PyTorch's `ClapFeatureExtractor`
/// and that the full Swift→Core ML path reproduces the PyTorch-fed embedding.
/// The deterministic synthetic waveform mirrors `cmd_golden` in
/// `convert_clap_to_coreml.py`, so no audio file is needed.
///
/// Skips when the model/fixtures are absent (e.g. CI without the large
/// `.mlpackage` files — see EMBEDDING_NOTES.md).
final class CLAPEmbeddingTests: XCTestCase {

    // Must match GOLDEN_SINES in convert_clap_to_coreml.py.
    private let sines: [(freq: Double, amp: Double)] =
        [(110, 0.5), (440, 0.25), (1760, 0.15), (6000, 0.1)]

    private func goldenWaveform() -> [Float] {
        let sr = Double(CLAPMel.sampleRate), n = CLAPMel.clipSamples
        var w = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            var s = 0.0
            for (f, a) in sines { s += a * sin(2.0 * .pi * f * t) }
            w[i] = Float(s)
        }
        return w
    }

    private func loadF32(_ url: URL) throws -> [Float] {
        try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func requireDir() throws -> URL {
        guard let dir = CLAPModel.resourceDir(),
              FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("golden_embedding.f32").path) else {
            throw XCTSkip("CLAP model/fixtures not present — skipping")
        }
        return dir
    }

    /// Swift mel front-end matches the PyTorch golden mel.
    func testMelMatchesPyTorch() throws {
        let dir = try requireDir()
        let filters = try loadF32(dir.appendingPathComponent("clap_mel_filters.f32"))
        let goldenMel = try loadF32(dir.appendingPathComponent("golden_mel.f32"))

        let mel = CLAPMel(melFilters: filters).logMel(goldenWaveform())
        XCTAssertEqual(mel.count, goldenMel.count, "mel length")
        XCTAssertEqual(mel.count, CLAPMel.frames * CLAPMel.nMels)

        var sumAbs = 0.0, maxAbs = 0.0
        for i in 0..<mel.count {
            let d = abs(Double(mel[i] - goldenMel[i]))
            sumAbs += d
            maxAbs = max(maxAbs, d)
        }
        let meanAbs = sumAbs / Double(mel.count)
        print("[CLAP test] mel mean|Δ|=\(meanAbs) dB, max|Δ|=\(maxAbs) dB")
        // float32(Swift) vs float64(numpy) + bilinear-free front-end: tight.
        XCTAssertLessThan(meanAbs, 0.5, "mean mel error too high")
    }

    /// Full Swift→Core ML embedding reproduces the PyTorch-fed golden embedding.
    func testEmbeddingMatchesGolden() throws {
        _ = try requireDir()
        guard let model = CLAPModel.load() else { throw XCTSkip("CLAP model not loadable") }
        let dir = try requireDir()
        let golden = try loadF32(dir.appendingPathComponent("golden_embedding.f32"))

        let emb = try model.embed(samples: goldenWaveform())
        XCTAssertEqual(emb.count, CLAPModel.embeddingDim)

        // both L2-normalized -> dot == cosine
        var cos: Float = 0
        for i in 0..<emb.count { cos += emb[i] * golden[i] }
        print("[CLAP test] embedding cosine vs golden = \(cos)")
        XCTAssertGreaterThan(cos, 0.999, "Swift embedding diverges from PyTorch path")
    }

    /// Moods return a finite cosine score for every label.
    func testMoodsProduceScores() throws {
        _ = try requireDir()
        guard let model = CLAPModel.load() else { throw XCTSkip("CLAP model not loadable") }
        let emb = try model.embed(samples: goldenWaveform())
        let moods = model.moods(forEmbedding: emb)
        XCTAssertEqual(moods.count, 6, "expected 6 mood labels")
        for (label, score) in moods {
            XCTAssert(score.isFinite, "\(label) score not finite")
            XCTAssert(score >= -1.001 && score <= 1.001, "\(label) cosine out of range: \(score)")
        }
    }
}
