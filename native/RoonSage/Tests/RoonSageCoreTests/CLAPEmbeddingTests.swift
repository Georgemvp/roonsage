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

    /// Pin Core ML to the CPU for the whole test process. Apple's MPSGraph
    /// aborts (`shape.count = 0 != strides.count = 2`) in roughly a third of
    /// short-lived test runs on the accelerated path; measured 5 crashes in 16
    /// runs on `.all` versus 0 in 24 on `.cpuOnly`. The assertions below are
    /// unchanged — only the backend differs. Production stays on `.all` (see
    /// CLAPModel.swift): the analyzer has never hit this in 70 sessions.
    override class func setUp() {
        super.setUp()
        setenv("ROONSAGE_CLAP_CPU_ONLY", "1", 1)
    }

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

    /// Sanity: identical input → cosine ≈ 1; a very different signal scores
    /// strictly lower. Guards against a degenerate/constant embedding.
    func testEmbeddingDiscriminates() throws {
        _ = try requireDir()
        guard let model = CLAPModel.load() else { throw XCTSkip("CLAP model not loadable") }

        let a = try model.embed(samples: goldenWaveform())
        let b = try model.embed(samples: goldenWaveform())
        // A pure 8 kHz tone — spectrally unlike the multi-sine golden signal.
        let sr = Double(CLAPMel.sampleRate)
        let tone = (0..<CLAPMel.clipSamples).map { Float(0.5 * sin(2.0 * .pi * 8000.0 * Double($0) / sr)) }
        let c = try model.embed(samples: tone)

        func cos(_ x: [Float], _ y: [Float]) -> Float { zip(x, y).reduce(0) { $0 + $1.0 * $1.1 } }
        let same = cos(a, b), diff = cos(a, c)
        print("[CLAP test] cos(same)=\(same)  cos(diff)=\(diff)")
        XCTAssertEqual(same, 1.0, accuracy: 1e-3, "identical input must embed identically")
        XCTAssertLessThan(diff, same - 0.05, "a different signal must score clearly lower")
    }

    /// Full-track windowing (v3): the mean direction of a long signal's 10 s
    /// windows is unit-norm and, for a homogeneous (seamlessly repeated)
    /// signal, ≈ the single-window embedding. Every golden sine completes an
    /// integer number of cycles in 10 s, so repetition is phase-continuous.
    func testWindowedEmbeddingMatchesSingleForHomogeneousSignal() throws {
        _ = try requireDir()
        guard let model = CLAPModel.load() else { throw XCTSkip("CLAP model not loadable") }
        let base = goldenWaveform()                       // exactly 10 s
        var long = [Float]()
        for _ in 0..<3 { long.append(contentsOf: base) }  // 30 s -> windows at 0/5/10/15/20 s
        let windowed = try model.embedWindowed(samples: long)
        let single = try model.embed(samples: base)

        var norm: Float = 0
        for v in windowed { norm += v * v }
        XCTAssertEqual(norm, 1.0, accuracy: 1e-3, "windowed embedding must be unit-norm")
        let cos = zip(windowed, single).reduce(0) { $0 + $1.0 * $1.1 }
        XCTAssertGreaterThan(cos, 0.95, "homogeneous signal: windowed must ≈ single-window")
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
