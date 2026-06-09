import Foundation

/// Tempo (BPM) estimation: spectral-flux onset envelope → autocorrelation peak.
public struct TempoAnalyzer {

    public static func bpm(
        _ samples: [Float],
        sampleRate: Double,
        frameSize: Int = 1024,
        hop: Int = 512
    ) -> (bpm: Double, confidence: Double) {
        guard samples.count > frameSize * 8 else { return (0, 0) }

        let fft = RealFFT(size: frameSize)
        let window = hannWindow(frameSize)
        let half = frameSize / 2

        var prev = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        var onset: [Float] = []
        onset.reserveCapacity(samples.count / hop + 1)
        var frame = [Float](repeating: 0, count: frameSize)

        var i = 0
        while i + frameSize <= samples.count {
            for j in 0..<frameSize { frame[j] = samples[i + j] * window[j] }
            fft.magnitudes(frame, into: &mag)
            var flux: Float = 0
            for j in 0..<half {
                let d = mag[j] - prev[j]
                if d > 0 { flux += d }
            }
            onset.append(flux)
            swap(&prev, &mag)   // O(1) buffer swap instead of copying the spectrum
            i += hop
        }

        // Detrend: half-wave rectify around the mean.
        let mean = onset.reduce(0, +) / Float(max(onset.count, 1))
        let env = onset.map { max(0, $0 - mean) }

        let onsetSR = sampleRate / Double(hop)
        let minBpm = 60.0, maxBpm = 200.0
        let minLag = max(1, Int((onsetSR * 60.0 / maxBpm).rounded()))
        let maxLag = min(env.count - 1, Int((onsetSR * 60.0 / minBpm).rounded()))
        guard maxLag > minLag else { return (0, 0) }

        // Weight each candidate tempo by a log-Gaussian prior centred on 120 BPM.
        // This resolves octave ambiguity (half/double/triplet) without blind
        // folding — the standard librosa-style approach.
        func prior(_ bpm: Double) -> Double {
            let z = (log2(bpm) - log2(120.0)) / 0.9
            return exp(-0.5 * z * z)
        }

        var bestScore = -Double.infinity
        var bestVal: Float = 0
        var bestBpm = 0.0
        var total: Float = 0
        for lag in minLag...maxLag {
            var sum: Float = 0
            var k = 0
            let limit = env.count - lag
            while k < limit { sum += env[k] * env[k + lag]; k += 1 }
            total += sum
            let bpm = 60.0 * onsetSR / Double(lag)
            let score = Double(sum) * prior(bpm)
            if score > bestScore { bestScore = score; bestVal = sum; bestBpm = bpm }
        }

        let confidence = total > 0 ? min(1.0, Double(bestVal / total) * Double(maxLag - minLag) / 4.0) : 0
        return ((bestBpm * 10).rounded() / 10, confidence)
    }
}
