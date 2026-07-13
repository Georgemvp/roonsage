import AudioAnalysis
import Foundation

// MARK: - Discovery sonic-fit (CLAP long-tail, fase 1)
//
// Candidates we don't own were never analyzed, so they carry no CLAP embedding —
// the discovery score can only lean on collaborative/metadata signals. This
// closes that gap for the top of a batch: fetch a 30 s Deezer preview, CLAP-embed
// it, and cosine it against the user's (L2-normalized) taste centroid, then fold
// that sonic fit into the score as a small bounded nudge. Best-effort: a missing
// preview, a failed decode, or no loaded CLAP model simply leaves the score
// untouched (the batch degrades to its pre-sonic ranking). The `nudge` mapping is
// pure and unit-tested; `cosineToTaste` is network/IO glue like every producer.

public enum DiscoverySonicFit {

    /// Max score nudge from sonic fit — bounded, like the album/popularity
    /// modifiers, so a miscalibrated cosine can only re-rank within the ballpark,
    /// never dominate the collaborative/metadata score.
    public static let sonicFitWeight = 0.12

    /// Cosine at which sonic fit is neutral (no nudge). Both vectors are L2-
    /// normalized, so cosine ∈ [-1, 1]; a track vs a taste centroid clusters in
    /// roughly [0, 0.6], so 0.3 is a sensible middle.
    public static let neutralCosine = 0.3

    /// How far above/below `neutral` a cosine must sit to reach the full ±weight.
    static let cosineScale = 0.3

    /// Map a CLAP cosine to a bounded ± nudge: above `neutral` lifts, below trims,
    /// clamped to ±`weight`. Linear between, saturating at ±1·weight.
    public static func nudge(cosine: Double, neutral: Double = neutralCosine, weight: Double = sonicFitWeight) -> Double {
        let t = max(-1, min(1, (cosine - neutral) / cosineScale))
        return weight * t
    }

    /// Download `previewURL` to a temp `.mp3`, CLAP-embed it, and cosine against
    /// the taste centroid. nil on any download/decode/embed failure (caller then
    /// leaves the score untouched). Mirrors AnalyzerCore's PreviewEmbeddingBackfill:
    /// AVFoundation sniffs by extension, so the temp file MUST end in `.mp3`
    /// (Deezer previews are MP3). The temp file is always cleaned up.
    public static func cosineToTaste(previewURL: URL, centroid: [Float], clap: CLAPModel) async -> Double? {
        guard let (tmp, _) = try? await URLSession.shared.download(from: previewURL) else { return nil }
        let mp3 = tmp.deletingPathExtension().appendingPathExtension("mp3")
        try? FileManager.default.moveItem(at: tmp, to: mp3)
        defer { try? FileManager.default.removeItem(at: mp3) }
        guard let embedding = try? clap.embed(url: mp3),
              embedding.count == centroid.count, !centroid.isEmpty else { return nil }
        // Both vectors are L2-normalized (CLAP embeddings and the taste centroid),
        // so their dot product IS the cosine similarity.
        var acc: Float = 0
        for i in 0..<embedding.count { acc += embedding[i] * centroid[i] }
        return Double(acc)
    }
}

/// One-time, best-effort CLAP handle for the discovery pipeline's sonic-fit
/// re-rank. RoonSageCore has no loaded model of its own (the analyzer app loads
/// its own separately for analysis); this loads one lazily, once per process.
/// nil when the CLAP models aren't present — which disables sonic fit silently.
public actor SonicFitClap {
    public static let shared = SonicFitClap()
    private var attempted = false
    private var cached: CLAPModel?

    public func model() async -> CLAPModel? {
        if attempted { return cached }
        attempted = true
        cached = CLAPModel.load()   // heavy but one-time; nil if models absent
        return cached
    }
}
