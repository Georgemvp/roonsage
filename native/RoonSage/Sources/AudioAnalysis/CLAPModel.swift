import Accelerate
import CoreML
import Foundation

/// Native CLAP inference. Wraps the two Core ML packages produced by
/// `native/scripts/convert_clap_to_coreml.py` and turns audio into a 512-dim
/// L2-normalized embedding in CLAP's shared audio/text space, plus mood scores
/// via cosine against precomputed (Core ML) mood-label embeddings.
///
/// Loading is best-effort: `load()` returns nil (and logs) when the models are
/// absent, so the analyzer degrades gracefully to scalar-only features.
public final class CLAPModel: @unchecked Sendable {
    public static let embeddingDim = 512
    public let modelVersion: String

    private let audioModel: MLModel
    private let textModel: MLModel
    private let mel: CLAPMel
    private let moodLabels: [String]
    private let moodEmbeds: [[Float]]   // [label][512], L2-normalized

    // MARK: - Loading

    /// Resolve the directory holding the `.mlpackage` files + `.f32` resources.
    /// Order: `ROONSAGE_CLAP_DIR` env → dev path next to this source file.
    /// (SPM `Bundle.module` wiring is deferred until the model-shipping
    /// decision in EMBEDDING_NOTES.md is made.)
    static func resourceDir() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["ROONSAGE_CLAP_DIR"], !env.isEmpty {
            let u = URL(fileURLWithPath: env)
            if fm.fileExists(atPath: u.path) { return u }
        }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/CLAP", isDirectory: true)
        return fm.fileExists(atPath: dev.path) ? dev : nil
    }

    public static func load() -> CLAPModel? {
        guard let dir = resourceDir() else {
            NSLog("[CLAP] no model directory found — embeddings disabled")
            return nil
        }
        do { return try CLAPModel(dir: dir) }
        catch {
            NSLog("[CLAP] failed to load model: \(error) — embeddings disabled")
            return nil
        }
    }

    init(dir: URL) throws {
        let cfg = try MelConfig(dir: dir)
        self.modelVersion = "clap-\(cfg.model.split(separator: "/").last ?? "")-v1"

        let filters = try Self.loadF32(dir.appendingPathComponent("clap_mel_filters.f32"))
        self.mel = CLAPMel(melFilters: filters)

        let audioURL = dir.appendingPathComponent("CLAPAudio.mlpackage")
        let textURL = dir.appendingPathComponent("CLAPText.mlpackage")
        let cfgML = MLModelConfiguration()
        self.audioModel = try MLModel(contentsOf: MLModel.compileModel(at: audioURL), configuration: cfgML)
        self.textModel = try MLModel(contentsOf: MLModel.compileModel(at: textURL), configuration: cfgML)

        self.moodLabels = cfg.moodLabels
        let moodFlat = try Self.loadF32(dir.appendingPathComponent("clap_mood_embeds.f32"))
        let d = Self.embeddingDim
        precondition(moodFlat.count == cfg.moodLabels.count * d, "mood embeds size mismatch")
        self.moodEmbeds = (0..<cfg.moodLabels.count).map { Array(moodFlat[$0 * d..<($0 + 1) * d]) }
    }

    // MARK: - Audio embedding

    /// 512-dim L2-normalized embedding for mono samples at 48 kHz.
    public func embed(samples: [Float]) throws -> [Float] {
        let logMel = mel.logMel(samples)   // [frames * nMels], row-major
        let arr = try MLMultiArray(
            shape: [1, 1, NSNumber(value: CLAPMel.frames), NSNumber(value: CLAPMel.nMels)],
            dataType: .float32)
        logMel.withUnsafeBufferPointer { src in
            let dst = arr.dataPointer.assumingMemoryBound(to: Float.self)
            dst.update(from: src.baseAddress!, count: src.count)
        }
        let provider = try MLDictionaryFeatureProvider(
            dictionary: ["input_features": MLFeatureValue(multiArray: arr)])
        let out = try audioModel.prediction(from: provider)
        guard let emb = out.featureValue(for: "embedding")?.multiArrayValue else {
            throw CLAPError.missingOutput
        }
        return Self.l2(Self.toFloats(emb))
    }

    /// Decode a representative 48 kHz mono window and embed it.
    public func embed(url: URL) throws -> [Float] {
        let secs = Double(CLAPMel.clipSamples) / Double(CLAPMel.sampleRate)
        let audio = try AudioDecoder.decode(
            url: url, targetSampleRate: Double(CLAPMel.sampleRate),
            maxSeconds: secs, startFraction: 0)
        return try embed(samples: audio.samples)
    }

    // MARK: - Moods

    /// Cosine similarity of an audio embedding to each mood label.
    public func moods(forEmbedding emb: [Float]) -> [String: Float] {
        let e = Self.l2(emb)
        var result = [String: Float](minimumCapacity: moodLabels.count)
        for (i, label) in moodLabels.enumerated() {
            result[label] = Self.dot(e, moodEmbeds[i])
        }
        return result
    }

    // MARK: - Text (low-level; String tokenization arrives in Step 8)

    /// 512-dim L2-normalized text embedding from pre-tokenized ids + mask.
    public func textEmbedding(tokenIds: [Int32], attentionMask: [Int32]) throws -> [Float] {
        let len = tokenIds.count
        let ids = try MLMultiArray(shape: [1, NSNumber(value: len)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: len)], dataType: .int32)
        for i in 0..<len {
            ids[i] = NSNumber(value: tokenIds[i])
            mask[i] = NSNumber(value: attentionMask[i])
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids),
            "attention_mask": MLFeatureValue(multiArray: mask),
        ])
        let out = try textModel.prediction(from: provider)
        guard let emb = out.featureValue(for: "embedding")?.multiArrayValue else {
            throw CLAPError.missingOutput
        }
        return Self.l2(Self.toFloats(emb))
    }

    // MARK: - Helpers

    enum CLAPError: Error { case missingOutput }

    private static func loadF32(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    private static func toFloats(_ m: MLMultiArray) -> [Float] {
        let n = m.count
        var out = [Float](repeating: 0, count: n)
        if m.dataType == .float32 {
            let p = m.dataPointer.assumingMemoryBound(to: Float.self)
            out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: p, count: n) }
        } else {
            for i in 0..<n { out[i] = m[i].floatValue }
        }
        return out
    }

    static func l2(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = norm.squareRoot()
        guard norm > 1e-9 else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var inv = 1.0 / norm
        vDSP_vsmul(v, 1, &inv, &out, 1, vDSP_Length(v.count))
        return out
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(min(a.count, b.count)))
        return r
    }
}

/// Minimal decoder for `clap_mel.json` — only the fields Swift needs.
private struct MelConfig {
    let model: String
    let moodLabels: [String]

    init(dir: URL) throws {
        let data = try Data(contentsOf: dir.appendingPathComponent("clap_mel.json"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        self.model = obj["model"] as? String ?? "laion/clap"
        self.moodLabels = obj["mood_labels"] as? [String] ?? []
    }
}
