import Foundation

/// Musical key via chromagram + Krumhansl-Schmuckler key profiles.
public struct KeyAnalyzer {

    // Krumhansl-Schmuckler tonal hierarchy profiles (C-rooted).
    private static let major: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minor: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// Returns the tonic pitch class (0 = C … 11 = B) and mode.
    public static func detect(
        _ samples: [Float],
        sampleRate: Double,
        frameSize: Int = 4096,
        hop: Int = 2048
    ) -> (rootIndex: Int, mode: String) {
        guard samples.count > frameSize else { return (0, "major") }

        let fft = RealFFT(size: frameSize)
        let window = hannWindow(frameSize)
        let half = frameSize / 2

        // Precompute each bin's pitch class (0 = C). Restrict to the fundamental
        // band (~65–2000 Hz) where the tonic/harmony live; higher bins are mostly
        // overtones that smear major/minor discrimination.
        var pcOfBin = [Int](repeating: -1, count: half)
        for b in 1..<half {
            let freq = Double(b) * sampleRate / Double(frameSize)
            guard freq >= 65, freq <= 2000 else { continue }
            let midi = 69.0 + 12.0 * log2(freq / 440.0)
            pcOfBin[b] = ((Int(midi.rounded()) % 12) + 12) % 12
        }

        var chroma = [Float](repeating: 0, count: 12)
        var frame = [Float](repeating: 0, count: frameSize)
        var i = 0
        while i + frameSize <= samples.count {
            for j in 0..<frameSize { frame[j] = samples[i + j] * window[j] }
            let mag = fft.magnitudes(frame)
            // sqrt-compress magnitude so loud transients don't dominate the profile.
            for b in 1..<half where pcOfBin[b] >= 0 { chroma[pcOfBin[b]] += mag[b].squareRoot() }
            i += hop
        }

        let sum = chroma.reduce(0, +)
        if sum > 0 { for k in 0..<12 { chroma[k] /= sum } }

        var bestCorr: Float = -.infinity
        var bestRoot = 0
        var bestMode = "major"
        for root in 0..<12 {
            let rotated = (0..<12).map { chroma[($0 + root) % 12] }
            let cMaj = pearson(rotated, major)
            let cMin = pearson(rotated, minor)
            if cMaj > bestCorr { bestCorr = cMaj; bestRoot = root; bestMode = "major" }
            if cMin > bestCorr { bestCorr = cMin; bestRoot = root; bestMode = "minor" }
        }
        return (bestRoot, bestMode)
    }

    private static func pearson(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(a.count)
        let ma = a.reduce(0, +) / n
        let mb = b.reduce(0, +) / n
        var num: Float = 0, da: Float = 0, db: Float = 0
        for i in 0..<a.count {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        let den = (da * db).squareRoot()
        return den > 0 ? num / den : 0
    }
}
