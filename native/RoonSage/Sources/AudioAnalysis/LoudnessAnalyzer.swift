import Foundation

/// Perceptual loudness (K-weighted, ITU-R BS.1770 / EBU R128 style) in LUFS.
///
/// Where `AudioAnalyzer.rms` is a raw linear amplitude, this K-weights the signal
/// first — a high-shelf "head" filter + a high-pass "RLB" curve that approximate
/// how loud a track actually *sounds* — then integrates the mean square into a
/// LUFS value (a negative dB figure; louder → closer to 0). It's the metric the
/// DJ-set sequencer uses to avoid jarring level jumps between consecutive tracks,
/// independent of the intended energy arc.
///
/// The two biquads are re-derived at the actual sample rate (RBJ cookbook) from
/// BS.1770's filter specs, so it's correct at the analyzer's 22.05 kHz excerpt
/// rate, not only at 48 kHz. Absolute-loudness gating is intentionally omitted —
/// only the *relative* level between tracks matters here, and the ungated
/// integrated value is stable and monotonic for that.
public enum LoudnessAnalyzer {

    /// Integrated K-weighted loudness in LUFS, or nil for empty/silent input.
    public static func integratedLUFS(_ samples: [Float], sampleRate: Double) -> Double? {
        guard samples.count > 64, sampleRate > 0 else { return nil }

        let stage1 = highShelf(fc: 1681.974450955533, gainDB: 3.999843853973347,
                               q: 0.7071752369554196, fs: sampleRate)
        let stage2 = highPass(fc: 38.13547087602444, q: 0.5003270373238773, fs: sampleRate)

        // Direct Form I, cascaded. Double state to avoid drift over long buffers.
        var x1a = 0.0, x2a = 0.0, y1a = 0.0, y2a = 0.0
        var x1b = 0.0, x2b = 0.0, y1b = 0.0, y2b = 0.0
        var sumSq = 0.0
        for s in samples {
            let x0 = Double(s)
            let a = stage1.b0 * x0 + stage1.b1 * x1a + stage1.b2 * x2a - stage1.a1 * y1a - stage1.a2 * y2a
            x2a = x1a; x1a = x0; y2a = y1a; y1a = a
            let b = stage2.b0 * a + stage2.b1 * x1b + stage2.b2 * x2b - stage2.a1 * y1b - stage2.a2 * y2b
            x2b = x1b; x1b = a; y2b = y1b; y1b = b
            sumSq += b * b
        }
        let meanSq = sumSq / Double(samples.count)
        guard meanSq > 1e-12 else { return nil }   // effectively silent
        return -0.691 + 10 * log10(meanSq)
    }

    // MARK: - RBJ biquads (normalized so a0 == 1)

    private struct Biquad { var b0, b1, b2, a1, a2: Double }

    private static func highShelf(fc: Double, gainDB: Double, q: Double, fs: Double) -> Biquad {
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * fc / fs
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * q)
        let sqrtA2alpha = 2 * A.squareRoot() * alpha
        let b0 =  A * ((A + 1) + (A - 1) * cw + sqrtA2alpha)
        let b1 = -2 * A * ((A - 1) + (A + 1) * cw)
        let b2 =  A * ((A + 1) + (A - 1) * cw - sqrtA2alpha)
        let a0 =       (A + 1) - (A - 1) * cw + sqrtA2alpha
        let a1 =  2 * ((A - 1) - (A + 1) * cw)
        let a2 =       (A + 1) - (A - 1) * cw - sqrtA2alpha
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    private static func highPass(fc: Double, q: Double, fs: Double) -> Biquad {
        let w0 = 2 * Double.pi * fc / fs
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * q)
        let b0 =  (1 + cw) / 2
        let b1 = -(1 + cw)
        let b2 =  (1 + cw) / 2
        let a0 =   1 + alpha
        let a1 =  -2 * cw
        let a2 =   1 - alpha
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}
