import AudioAnalysis
import Foundation

public struct AnalyzeProgress: Sendable {
    public var done: Int
    public var total: Int
    public var failed: Int
    public var rate: Double        // files/sec
    public var etaSeconds: Double
}

/// Walks a music directory, analyzes new/changed files concurrently, stores
/// results. Resumable (skips files already analyzed by path+mtime).
public final class LibraryWalker {
    public static let audioExtensions: Set<String> = ["flac", "m4a", "mp3", "wav", "aiff", "aif", "alac", "aac"]

    private let store: FeatureStore
    private let concurrency: Int
    private let clap: CLAPModel?
    private let excerptSeconds: Double
    private let sampleRate: Double
    private var cancelled = false

    /// Default concurrency is low (3): the library typically lives on a slow
    /// external HDD where many parallel reads thrash the disk (seek contention)
    /// and *reduce* throughput. Raise it only for fast (SSD/local) storage.
    /// Pass a loaded `clap` to compute sonic embeddings during the walk.
    /// `excerptSeconds`/`sampleRate` control the analysed window (less I/O on slow
    /// drives) vs precision — user-tunable; take effect on the next (re-)analysis.
    public init(store: FeatureStore, concurrency: Int = 3, clap: CLAPModel? = nil,
                excerptSeconds: Double = 120, sampleRate: Double = 22050) {
        self.store = store
        self.concurrency = max(1, concurrency)
        self.clap = clap
        self.excerptSeconds = max(0, excerptSeconds)
        self.sampleRate = sampleRate > 0 ? sampleRate : 22050
    }

    private enum Mode: Sendable { case full, embeddingOnly }
    private enum WalkResult: Sendable {
        case full(TrackFeatureRow)
        case embeddingOnly(path: String, mtime: Double, embedding: [Float]?, model: String, moods: String?, attributes: String?)
        case failed
    }

    public func cancel() { cancelled = true }

    /// Streams the directory walk: discovers and analyzes files as it goes, so
    /// analysis starts immediately and overlaps the (slow) enumeration. Returns
    /// (analyzed, failed). `total` in progress is the running discovered count.
    @discardableResult
    public func run(musicDir: String, onProgress: @escaping @Sendable (AnalyzeProgress) -> Void) async -> (analyzed: Int, failed: Int) {
        cancelled = false
        let iso = ISO8601DateFormatter()
        let t0 = Date()
        var done = 0, failed = 0, discovered = 0

        guard let en = FileManager.default.enumerator(
            at: URL(fileURLWithPath: musicDir),
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return (0, 0) }

        let currentModel = clap?.modelVersion
        let excerpt = excerptSeconds, sr = sampleRate   // local copies (avoid self-capture in @Sendable tasks)
        await withTaskGroup(of: WalkResult.self) { group in
            var inFlight = 0
            // Buffer analyzed rows and persist in one transaction per chunk instead
            // of one per track (far fewer WAL commits). Resumable, so the small
            // unflushed tail on a crash is simply re-analyzed next run.
            var pendingFull: [TrackFeatureRow] = []
            func flush() {
                guard !pendingFull.isEmpty else { return }
                try? store.upsertBatch(pendingFull)
                pendingFull.removeAll(keepingCapacity: true)
            }
            func drainOne() async {
                guard let result = await group.next() else { return }
                inFlight -= 1
                switch result {
                case .full(let row):
                    pendingFull.append(row); done += 1
                    if pendingFull.count >= 64 { flush() }
                case .embeddingOnly(let p, let m, let e, let mv, let mo, let at):
                    try? store.setEmbedding(path: p, mtime: m, embedding: e, model: mv, moods: mo, attributes: at); done += 1
                case .failed: failed += 1
                }
                let processed = done + failed
                let rate = Double(processed) / max(0.001, Date().timeIntervalSince(t0))
                onProgress(AnalyzeProgress(
                    done: done, total: max(discovered, processed), failed: failed, rate: rate,
                    etaSeconds: rate > 0 ? Double(max(0, discovered - processed)) / rate : 0
                ))
            }

            for case let url as URL in en {
                if cancelled { break }
                guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                guard let mtime = Self.mtime(url) else { continue }

                let mode: Mode
                if let currentModel {
                    let st = store.rowState(path: url.path, mtime: mtime)
                    if st.exists && st.model == currentModel { continue }   // fully analyzed
                    mode = st.exists ? .embeddingOnly : .full               // keep scalars if present
                } else {
                    if store.isAnalyzed(path: url.path, mtime: mtime) { continue }
                    mode = .full
                }
                discovered += 1
                let clap = self.clap
                group.addTask { Self.process(url, mtime: mtime, mode: mode, clap: clap, excerptSeconds: excerpt, sampleRate: sr, isoFormatter: iso) }
                inFlight += 1
                while inFlight >= concurrency { await drainOne() }
            }
            while inFlight > 0 { await drainOne() }
            flush()   // persist the tail (also covers the cancel path)
            group.cancelAll()
        }
        return (done, failed)
    }

    private static func process(_ url: URL, mtime: Double, mode: Mode,
                                clap: CLAPModel?, excerptSeconds: Double, sampleRate: Double,
                                isoFormatter: ISO8601DateFormatter) -> WalkResult {
        switch mode {
        case .embeddingOnly:
            // Scalars already stored — only (re)compute the embedding. We mark
            // the row with the current model version even on failure so a
            // permanently-unembeddable file isn't retried every run.
            guard let clap else { return .failed }
            if let emb = try? clap.embed(url: url) {
                return .embeddingOnly(path: url.path, mtime: mtime, embedding: emb,
                                      model: clap.modelVersion,
                                      moods: encodeFloatMap(clap.moods(forEmbedding: emb)),
                                      attributes: encodeFloatMap(clap.attributes(forEmbedding: emb)))
            }
            return .embeddingOnly(path: url.path, mtime: mtime, embedding: nil,
                                  model: clap.modelVersion, moods: nil, attributes: nil)
        case .full:
            let meta = MetadataReader.read(url: url)
            guard let f = try? AudioAnalyzer.analyze(url: url, sampleRate: sampleRate,
                                                     excerptSeconds: excerptSeconds, clap: clap) else { return .failed }
            let key = TrackIdentity.matchKey(artist: meta.artist, album: meta.album, title: meta.title)
            guard !key.replacingOccurrences(of: "\u{1f}", with: "").isEmpty else { return .failed }
            return .full(TrackFeatureRow(
                matchKey: key, artist: meta.artist, title: meta.title, album: meta.album, year: meta.year,
                filePath: url.path, fileMtime: mtime,
                bpm: f.bpm, bpmConfidence: f.bpmConfidence, keyRoot: f.keyRoot, keyMode: f.keyMode,
                camelot: f.camelot, energy: f.energy, duration: f.durationSec,
                tags: nil, analyzedAt: isoFormatter.string(from: Date()),
                embedding: f.embedding.isEmpty ? nil : f.embedding,
                // Stamp the current model version whenever CLAP ran (even on a
                // failed embed) so the file isn't re-tried every walk; nil when
                // CLAP is disabled so enabling it later triggers an embed pass.
                embeddingModel: clap.map { $0.modelVersion },
                moods: f.moods.isEmpty ? nil : encodeFloatMap(f.moods),
                attributes: f.attributes.isEmpty ? nil : encodeFloatMap(f.attributes)
            ))
        }
    }

    private static func encodeFloatMap(_ m: [String: Float]) -> String? {
        guard !m.isEmpty, let data = try? JSONEncoder().encode(m) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Backfill attributes for rows that already have an embedding but no
    /// attributes — derived from the STORED vector, no audio re-read. Lets an
    /// existing analyzed library gain the new axes without a full re-scan.
    /// Returns the number of rows updated.
    @discardableResult
    public func backfillAttributes(batch: Int = 200,
                                   onProgress: (@Sendable (Int) -> Void)? = nil) async -> Int {
        guard let clap else { return 0 }
        cancelled = false
        var total = 0
        while !cancelled {
            let rows = store.attributeBackfillRows(limit: batch)
            if rows.isEmpty { break }
            for r in rows {
                // Storing "{}" when probes are unavailable marks the row done so it
                // isn't re-selected (avoids an infinite loop).
                let json = Self.encodeFloatMap(clap.attributes(forEmbedding: r.embedding)) ?? "{}"
                try? store.setAttributes(path: r.path, mtime: r.mtime, attributes: json)
                total += 1
            }
            onProgress?(total)
        }
        return total
    }

    public static func mtime(_ url: URL) -> Double? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970
    }

    public static func findAudioFiles(_ root: URL) -> [URL] {
        var result: [URL] = []
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in en where audioExtensions.contains(url.pathExtension.lowercased()) {
            result.append(url)
        }
        return result
    }
}
