import Accelerate
import Foundation

public struct AudioFeatures: Sendable, Codable {
    public var bpm: Double
    public var bpmConfidence: Double
    public var keyRoot: String       // "C", "C#", …
    public var keyMode: String       // "major" | "minor"
    public var camelot: String       // "8A", "5B", …
    public var energy: Double        // RMS, 0…1-ish
    public var durationSec: Double
}

/// Top-level analyzer: decode → BPM + key/Camelot + energy.
public struct AudioAnalyzer {

    /// `excerptSeconds > 0` analyzes only a representative window (default 120s
    /// from 15% in) — much less I/O on slow drives, with BPM/key/energy that
    /// stay representative. Pass 0 to analyze the whole track.
    public static func analyze(
        url: URL,
        sampleRate: Double = 22050,
        excerptSeconds: Double = 120,
        excerptStart: Double = 0   // read from the start — FLAC seek via AVFoundation is very slow
    ) throws -> AudioFeatures {
        let audio = try AudioDecoder.decode(
            url: url, targetSampleRate: sampleRate,
            maxSeconds: excerptSeconds, startFraction: excerptStart
        )
        let (bpm, conf) = TempoAnalyzer.bpm(audio.samples, sampleRate: audio.sampleRate)
        let key = KeyAnalyzer.detect(audio.samples, sampleRate: audio.sampleRate)
        return AudioFeatures(
            bpm: bpm,
            bpmConfidence: conf,
            keyRoot: Camelot.note(rootIndex: key.rootIndex),
            keyMode: key.mode,
            camelot: Camelot.code(rootIndex: key.rootIndex, mode: key.mode),
            energy: rms(audio.samples),
            durationSec: audio.fullDurationSec > 0 ? audio.fullDurationSec : audio.duration
        )
    }

    static func rms(_ s: [Float]) -> Double {
        guard !s.isEmpty else { return 0 }
        var sumSq: Float = 0
        vDSP_svesq(s, 1, &sumSq, vDSP_Length(s.count))
        return Double((sumSq / Float(s.count)).squareRoot())
    }
}
