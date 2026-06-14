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

    // v13-era sonic embedding (Track E5). Empty when CLAP is unavailable.
    public var embedding: [Float] = []                 // 512-dim, L2-normalized
    public var moods: [String: Float] = [:]            // mood label → cosine
    public var embeddingModelVersion: String = ""      // e.g. "clap-…-v1"

    public init(bpm: Double, bpmConfidence: Double, keyRoot: String, keyMode: String,
                camelot: String, energy: Double, durationSec: Double,
                embedding: [Float] = [], moods: [String: Float] = [:],
                embeddingModelVersion: String = "") {
        self.bpm = bpm; self.bpmConfidence = bpmConfidence
        self.keyRoot = keyRoot; self.keyMode = keyMode; self.camelot = camelot
        self.energy = energy; self.durationSec = durationSec
        self.embedding = embedding; self.moods = moods
        self.embeddingModelVersion = embeddingModelVersion
    }

    // Custom decode so older payloads without the embedding fields still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bpm = try c.decode(Double.self, forKey: .bpm)
        bpmConfidence = try c.decode(Double.self, forKey: .bpmConfidence)
        keyRoot = try c.decode(String.self, forKey: .keyRoot)
        keyMode = try c.decode(String.self, forKey: .keyMode)
        camelot = try c.decode(String.self, forKey: .camelot)
        energy = try c.decode(Double.self, forKey: .energy)
        durationSec = try c.decode(Double.self, forKey: .durationSec)
        embedding = try c.decodeIfPresent([Float].self, forKey: .embedding) ?? []
        moods = try c.decodeIfPresent([String: Float].self, forKey: .moods) ?? [:]
        embeddingModelVersion = try c.decodeIfPresent(String.self, forKey: .embeddingModelVersion) ?? ""
    }
}

/// Top-level analyzer: decode → BPM + key/Camelot + energy.
public struct AudioAnalyzer {

    /// `excerptSeconds > 0` analyzes only a representative window (default 120s
    /// from 15% in) — much less I/O on slow drives, with BPM/key/energy that
    /// stay representative. Pass 0 to analyze the whole track.
    /// Pass a loaded `clap` model to additionally compute the 512-dim sonic
    /// embedding + mood scores. CLAP decodes its own 48 kHz 10 s window, so the
    /// BPM/key path is unchanged; a CLAP failure degrades to scalar-only.
    public static func analyze(
        url: URL,
        sampleRate: Double = 22050,
        excerptSeconds: Double = 120,
        excerptStart: Double = 0,  // read from the start — FLAC seek via AVFoundation is very slow
        clap: CLAPModel? = nil
    ) throws -> AudioFeatures {
        let audio = try AudioDecoder.decode(
            url: url, targetSampleRate: sampleRate,
            maxSeconds: excerptSeconds, startFraction: excerptStart
        )
        let (bpm, conf) = TempoAnalyzer.bpm(audio.samples, sampleRate: audio.sampleRate)
        let key = KeyAnalyzer.detect(audio.samples, sampleRate: audio.sampleRate)

        var embedding: [Float] = []
        var moods: [String: Float] = [:]
        var modelVersion = ""
        if let clap, let emb = try? clap.embed(url: url) {
            embedding = emb
            moods = clap.moods(forEmbedding: emb)
            modelVersion = clap.modelVersion
        }

        return AudioFeatures(
            bpm: bpm,
            bpmConfidence: conf,
            keyRoot: Camelot.note(rootIndex: key.rootIndex),
            keyMode: key.mode,
            camelot: Camelot.code(rootIndex: key.rootIndex, mode: key.mode),
            energy: rms(audio.samples),
            durationSec: audio.fullDurationSec > 0 ? audio.fullDurationSec : audio.duration,
            embedding: embedding,
            moods: moods,
            embeddingModelVersion: modelVersion
        )
    }

    static func rms(_ s: [Float]) -> Double {
        guard !s.isEmpty else { return 0 }
        var sumSq: Float = 0
        vDSP_svesq(s, 1, &sumSq, vDSP_Length(s.count))
        return Double((sumSq / Float(s.count)).squareRoot())
    }
}
