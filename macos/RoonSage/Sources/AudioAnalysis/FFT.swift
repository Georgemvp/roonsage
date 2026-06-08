import Accelerate

/// Reusable real-FFT (power-of-two size) producing a magnitude spectrum.
final class RealFFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init(size: Int) {
        precondition(size > 1 && (size & (size - 1)) == 0, "FFT size must be a power of two")
        n = size
        log2n = vDSP_Length(log2(Double(size)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Magnitude spectrum (length n/2) of a real frame of length n.
    func magnitudes(_ frame: [Float]) -> [Float] {
        let half = n / 2
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        return mags
    }
}

func hannWindow(_ n: Int) -> [Float] {
    var w = [Float](repeating: 0, count: n)
    vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    return w
}
