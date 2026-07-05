import AudioAnalysis
import Foundation

public struct PreviewProgress: Sendable {
    public var embedded: Int   // preview rows in the store (running total)
    public var checked: Int    // lookups attempted (incl. not-found)
    public var backlog: Int    // library tracks still without features
}

/// Embeds the *file-less* part of the library — the ~Qobuz-only tracks a local
/// analysis can never reach — from Deezer's 30-second MP3 previews, so they
/// become radio/similarity candidates like any analyzed track.
///
/// Per track: strict Deezer match (exact normalised artist AND cleaned title —
/// a wrong match poisons an embedding, not just a rank) → download the preview
/// to a temp file → run the regular analysis pipeline (CLAP embedding + moods +
/// attributes + tempo/key/energy off the 30s excerpt) → store under a
/// `preview://deezer/<id>` pseudo path with the LIBRARY's metadata, so the
/// `/features` export re-keys it exactly like the library row. Local playback
/// paths exclude these rows (`FeatureStore.previewPathPrefix`).
///
/// Trickle-friendly: single-flight, throttled, resumable (negative lookups are
/// memoised in `preview_lookups`), network-gentle (DeezerClient's reservation
/// gate spaces the API calls; previews come off a CDN).
public final class PreviewEmbeddingBackfill {
    private let store: FeatureStore
    private let clap: CLAPModel
    private let deezer: DeezerClient
    private let pageSize: Int
    private let throttleNanos: UInt64
    private var cancelled = false

    public init(store: FeatureStore, clap: CLAPModel, deezer: DeezerClient = .shared,
                pageSize: Int = 200, throttleMs: UInt64 = 400) {
        self.store = store
        self.clap = clap
        self.deezer = deezer
        self.pageSize = max(10, pageSize)
        self.throttleNanos = throttleMs * 1_000_000
    }

    public func cancel() { cancelled = true }

    /// `wants` pages through the library's unanalyzed tracks (limit, offset) —
    /// the analyzer app passes `RoonClient.unanalyzedTracks`. `backlog` is the
    /// total still-unanalyzed count (progress denominator). Returns the number
    /// of tracks embedded this run.
    @discardableResult
    public func run(
        backlog: @Sendable () async -> Int,
        wants: @Sendable (_ limit: Int, _ offset: Int) async -> [(matchKey: String, title: String, artist: String?, album: String?)],
        onProgress: @escaping @Sendable (PreviewProgress) -> Void
    ) async -> Int {
        cancelled = false
        let iso = ISO8601DateFormatter()
        var offset = 0
        var embeddedThisRun = 0
        var total = await backlog()

        while !cancelled {
            let page = await wants(pageSize, offset)
            if page.isEmpty { break }
            offset += page.count

            for want in page {
                if cancelled { break }
                // Already in the store (features not yet synced back to the
                // library) or already attempted → skip silently.
                if store.hasRow(matchKey: want.matchKey) { continue }
                if store.previewChecked(matchKey: want.matchKey) { continue }

                let hit = await deezer.preview(artist: want.artist ?? "", title: want.title)
                guard let hit else {
                    try? store.markPreviewChecked(matchKey: want.matchKey, found: false,
                                                  checkedAt: iso.string(from: Date()))
                    onProgress(PreviewProgress(embedded: store.previewRowCount(),
                                               checked: store.previewCheckedCount(), backlog: total))
                    continue
                }

                if let row = await Self.analyzePreview(hit: hit, want: want, clap: clap, iso: iso) {
                    try? store.upsertBatch([row])
                    embeddedThisRun += 1
                }
                // found=true even on a failed download/analysis: the preview
                // exists but isn't usable — retrying every run won't change that.
                try? store.markPreviewChecked(matchKey: want.matchKey, found: true,
                                              checkedAt: iso.string(from: Date()))
                onProgress(PreviewProgress(embedded: store.previewRowCount(),
                                           checked: store.previewCheckedCount(), backlog: total))
                if throttleNanos > 0 { try? await Task.sleep(nanoseconds: throttleNanos) }
            }
            total = await backlog()
        }
        return embeddedThisRun
    }

    /// Download one preview and run the standard analysis on it. nil on any
    /// download/decode failure. Static + off-actor, like the walker's `process`.
    private static func analyzePreview(
        hit: DeezerClient.PreviewHit,
        want: (matchKey: String, title: String, artist: String?, album: String?),
        clap: CLAPModel, iso: ISO8601DateFormatter
    ) async -> TrackFeatureRow? {
        guard let (tmp, _) = try? await URLSession.shared.download(from: hit.previewURL) else { return nil }
        // Give the decoder a recognisable extension (previews are MP3).
        let mp3 = tmp.deletingPathExtension().appendingPathExtension("mp3")
        try? FileManager.default.moveItem(at: tmp, to: mp3)
        defer { try? FileManager.default.removeItem(at: mp3) }

        guard let f = try? AudioAnalyzer.analyze(url: mp3, sampleRate: 22050,
                                                 excerptSeconds: 30, clap: clap) else { return nil }
        // Keyed + labeled with the LIBRARY's metadata (not Deezer's), so the
        // export's fresh TrackIdentity re-keying reproduces the library key.
        return TrackFeatureRow(
            matchKey: want.matchKey, artist: want.artist, title: want.title, album: want.album,
            year: nil,
            filePath: FeatureStore.previewPathPrefix + String(hit.id), fileMtime: 0,
            bpm: f.bpm, bpmConfidence: f.bpmConfidence,
            keyRoot: f.keyRoot, keyMode: f.keyMode, camelot: f.camelot,
            energy: f.energy,
            duration: hit.durationSec > 0 ? Double(hit.durationSec) : f.durationSec,
            tags: nil, analyzedAt: iso.string(from: Date()),
            loudness: nil,   // a 30s excerpt isn't comparable to the 120s LUFS window
            embedding: f.embedding.isEmpty ? nil : f.embedding,
            embeddingModel: clap.modelVersion,
            moods: encode(f.moods), attributes: encode(f.attributes))
    }

    private static func encode(_ m: [String: Float]) -> String? {
        guard !m.isEmpty, let data = try? JSONEncoder().encode(m) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
