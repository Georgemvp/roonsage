import Accelerate
import Foundation

/// Reproduces CLAP's `ClapFeatureExtractor` log-mel front-end in Swift so the
/// Swift-computed `input_features` match PyTorch bit-for-bit (the only residual
/// gap is the in-model bilinear-vs-bicubic resize — see EMBEDDING_NOTES.md).
///
/// Pipeline (non-fusion / repeatpad path, the one `larger_clap_music_and_speech`
/// uses): pad/truncate to 10 s → reflect-pad → framed periodic-Hann STFT →
/// power spectrum → slaney mel filter bank → power-to-dB.
struct CLAPMel {
    static let sampleRate = 48000
    static let nFFT = 1024
    static let hop = 480
    static let nMels = 64
    static let nFreqBins = nFFT / 2 + 1   // 513
    static let clipSamples = 480000       // 10 s
    static let frames = 1001              // 1 + 480000/480 (after center pad)

    /// Slaney mel filter bank, row-major `[nFreqBins][nMels]` (513×64), loaded
    /// from `clap_mel_filters.f32`.
    let melFilters: [Float]
    private let window: [Float]

    init(melFilters: [Float]) {
        precondition(melFilters.count == Self.nFreqBins * Self.nMels,
                     "mel filter bank must be \(Self.nFreqBins)×\(Self.nMels)")
        self.melFilters = melFilters
        // Periodic Hann: np.hanning(nFFT+1)[:-1] == 0.5 - 0.5·cos(2π n / nFFT).
        // NOT vDSP_HANN_NORM (that one is scaled differently).
        var w = [Float](repeating: 0, count: Self.nFFT)
        for n in 0..<Self.nFFT {
            w[n] = Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(n) / Double(Self.nFFT)))
        }
        window = w
    }

    /// Pad (repeat-then-zero) or center-truncate to exactly `clipSamples`.
    static func fitToClip(_ samples: [Float]) -> [Float] {
        let target = clipSamples
        if samples.count == target { return samples }
        if samples.count > target {
            // PyTorch uses random truncation; we pick a deterministic centered
            // window so analysis is reproducible.
            let start = (samples.count - target) / 2
            return Array(samples[start..<start + target])
        }
        // repeatpad: tile floor(target/len) times, then zero-pad the remainder.
        guard !samples.isEmpty else { return [Float](repeating: 0, count: target) }
        let nRepeat = max(1, target / samples.count)
        var out = [Float]()
        out.reserveCapacity(target)
        for _ in 0..<nRepeat {
            out.append(contentsOf: samples)
            if out.count >= target { break }
        }
        if out.count > target { out.removeLast(out.count - target) }
        if out.count < target { out.append(contentsOf: repeatElement(0, count: target - out.count)) }
        return out
    }

    /// numpy `np.pad(x, (p, p), mode="reflect")` — mirror without repeating edges.
    static func reflectPad(_ x: [Float], pad p: Int) -> [Float] {
        let n = x.count
        var out = [Float](repeating: 0, count: n + 2 * p)
        for k in 0..<p { out[k] = x[p - k] }                 // left:  x[p]…x[1]
        for i in 0..<n { out[p + i] = x[i] }                 // data
        for j in 0..<p { out[p + n + j] = x[n - 2 - j] }     // right: x[n-2]…x[n-1-p]
        return out
    }

    /// Returns the log-mel as a flat `[frames * nMels]` buffer in (frame, mel)
    /// row-major order — exactly the layout of `input_features` (1,1,1001,64).
    func logMel(_ samples: [Float]) -> [Float] {
        let clip = Self.fitToClip(samples)
        let padded = Self.reflectPad(clip, pad: Self.nFFT / 2)
        var out = [Float](repeating: 0, count: Self.frames * Self.nMels)

        // Local FFT (scratch buffers reused across all frames) so `logMel` is
        // reentrant — the analyzer worker shares one CLAPModel across threads.
        let fft = RealFFT(size: Self.nFFT)
        var frame = [Float](repeating: 0, count: Self.nFFT)
        var power = [Float](repeating: 0, count: Self.nFreqBins)
        var mel = [Float](repeating: 0, count: Self.nMels)
        let melFloor: Float = 1e-10

        for f in 0..<Self.frames {
            let t = f * Self.hop
            // windowed frame
            for i in 0..<Self.nFFT { frame[i] = padded[t + i] * window[i] }
            fft.powerSpectrum(frame, into: &power)

            // mel = power(1×513) · melFilters(513×64) -> (1×64), i.e. the
            // melFilters.T · power the extractor computes. mel_floor applied next.
            vDSP_mmul(power, 1, melFilters, 1, &mel, 1,
                      1, vDSP_Length(Self.nMels), vDSP_Length(Self.nFreqBins))
            // power_to_db: 10·log10(max(mel, 1e-10)); reference=1, no db_range.
            let base = f * Self.nMels
            for m in 0..<Self.nMels {
                out[base + m] = 10.0 * log10(max(mel[m], melFloor))
            }
        }
        return out
    }
}
