import Accelerate

/// Reusable real-FFT (power-of-two size) producing a magnitude spectrum.
/// Scratch buffers are allocated once and reused across frames — a hot loop
/// (hundreds of frames per track) no longer churns the allocator.
/// Not thread-safe: use one instance per analysis.
final class RealFFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var realp: [Float]
    private var imagp: [Float]

    init(size: Int) {
        precondition(size > 1 && (size & (size - 1)) == 0, "FFT size must be a power of two")
        n = size
        log2n = vDSP_Length(log2(Double(size)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        realp = [Float](repeating: 0, count: size / 2)
        imagp = [Float](repeating: 0, count: size / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Magnitude spectrum (length n/2) of a real frame of length n, written into
    /// `out` (resized to n/2 if needed). Reuses internal scratch buffers.
    func magnitudes(_ frame: [Float], into out: inout [Float]) {
        let half = n / 2
        if out.count != half { out = [Float](repeating: 0, count: half) }
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                out.withUnsafeMutableBufferPointer { op in
                    vDSP_zvabs(&split, 1, op.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }
    }

    /// Convenience allocating variant.
    func magnitudes(_ frame: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: n / 2)
        magnitudes(frame, into: &out)
        return out
    }

    /// Power spectrum (length n/2 + 1) of an already-windowed real frame,
    /// matching numpy's `np.abs(np.fft.rfft(x))**2`. Unlike `magnitudes` this
    /// keeps DC (bin 0) and Nyquist (bin n/2) as *separate* bins and undoes the
    /// ×2 scaling vDSP's packed real FFT applies — required for an exact match
    /// against the CLAP mel front-end. `out` is resized to n/2 + 1 if needed.
    func powerSpectrum(_ frame: [Float], into out: inout [Float]) {
        let half = n / 2
        if out.count != half + 1 { out = [Float](repeating: 0, count: half + 1) }
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // Packed format: realp[0] = 2·DC, imagp[0] = 2·Nyquist; bins
                // 1..half-1 are the usual complex pairs scaled by 2.
                out.withUnsafeMutableBufferPointer { op in
                    let dc = rp[0] * 0.5
                    let nyq = ip[0] * 0.5
                    op[0] = dc * dc
                    op[half] = nyq * nyq
                    for k in 1..<half {
                        let re = rp[k] * 0.5
                        let im = ip[k] * 0.5
                        op[k] = re * re + im * im
                    }
                }
            }
        }
    }
}

func hannWindow(_ n: Int) -> [Float] {
    var w = [Float](repeating: 0, count: n)
    vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    return w
}
