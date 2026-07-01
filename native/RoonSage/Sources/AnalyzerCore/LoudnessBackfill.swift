import AudioAnalysis
import Foundation

public struct LoudnessProgress: Sendable {
    public var done: Int       // tracks with a loudness value now
    public var total: Int      // total analyzed tracks
}

/// Backfills perceptual loudness (K-weighted LUFS, BS.1770) onto tracks analyzed
/// BEFORE F3 — the only way to fill it, since loudness can't be derived from the
/// stored embedding (unlike attributes); it needs the audio decoded again.
///
/// Deliberately GENTLE on the disk (the library lives on a slow external drive):
/// single-threaded with a small pause between files, so it trickles in the
/// background instead of saturating the drive like a full (parallel) analysis pass.
/// Resumable + idempotent — only rows with no loudness AND no `loudness_checked_at`
/// are decoded, so it stops the moment coverage is complete and a cancelled run
/// continues next launch. Uses the SAME excerpt window as a live analysis, so a
/// backfilled value is directly comparable to a freshly-analyzed one.
public final class LoudnessBackfill {
    private let store: FeatureStore
    private let batch: Int
    private let excerptSeconds: Double
    private let sampleRate: Double
    private let throttleNanos: UInt64
    private var cancelled = false

    public init(store: FeatureStore, batch: Int = 50, excerptSeconds: Double = 120,
                sampleRate: Double = 22050, throttleMs: UInt64 = 120) {
        self.store = store
        self.batch = max(1, batch)
        self.excerptSeconds = excerptSeconds
        self.sampleRate = sampleRate
        self.throttleNanos = throttleMs * 1_000_000
    }

    public func cancel() { cancelled = true }

    public func run(onProgress: @escaping @Sendable (LoudnessProgress) -> Void) async {
        let total = store.count()
        guard total > 0 else { return }

        while !cancelled {
            let tracks = store.tracksNeedingLoudness(limit: batch)
            if tracks.isEmpty { break }
            for t in tracks {
                if cancelled { break }
                // Decode off the current task hop is fine — one file at a time keeps
                // the drive from thrashing. A missing/corrupt file → nil → marked
                // checked so it isn't retried.
                let lufs = Self.measure(path: t.filePath, excerptSeconds: excerptSeconds, sampleRate: sampleRate)
                try? store.setLoudness(matchKey: t.matchKey, loudness: lufs, checkedAt: Self.now())
                onProgress(LoudnessProgress(done: store.loudnessCount(), total: total))
                if throttleNanos > 0 { try? await Task.sleep(nanoseconds: throttleNanos) }
            }
        }
    }

    /// Decode the representative excerpt and K-weight it to LUFS. Nil on any decode
    /// failure. `nonisolated`/static so it runs off the caller's actor.
    private static func measure(path: String, excerptSeconds: Double, sampleRate: Double) -> Double? {
        guard let audio = try? AudioDecoder.decode(
            url: URL(fileURLWithPath: path), targetSampleRate: sampleRate,
            maxSeconds: excerptSeconds, startFraction: 0), !audio.samples.isEmpty
        else { return nil }
        return LoudnessAnalyzer.integratedLUFS(audio.samples, sampleRate: audio.sampleRate)
    }

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}
