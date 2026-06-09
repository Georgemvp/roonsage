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
    private var cancelled = false

    public init(store: FeatureStore, concurrency: Int = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)) {
        self.store = store
        self.concurrency = concurrency
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

        await withTaskGroup(of: TrackFeatureRow?.self) { group in
            var inFlight = 0
            func drainOne() async {
                guard let result = await group.next() else { return }
                inFlight -= 1
                if let row = result { try? store.upsert(row); done += 1 } else { failed += 1 }
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
                if let mtime = Self.mtime(url), store.isAnalyzed(path: url.path, mtime: mtime) { continue }
                discovered += 1
                group.addTask { Self.analyzeFile(url, isoFormatter: iso) }
                inFlight += 1
                while inFlight >= concurrency { await drainOne() }
            }
            while inFlight > 0 { await drainOne() }
            group.cancelAll()
        }
        return (done, failed)
    }

    private static func analyzeFile(_ url: URL, isoFormatter: ISO8601DateFormatter) -> TrackFeatureRow? {
        guard let mtime = mtime(url) else { return nil }
        let meta = MetadataReader.read(url: url)
        guard let f = try? AudioAnalyzer.analyze(url: url) else { return nil }
        let key = TrackIdentity.matchKey(artist: meta.artist, album: meta.album, title: meta.title)
        guard !key.replacingOccurrences(of: "\u{1f}", with: "").isEmpty else { return nil }
        return TrackFeatureRow(
            matchKey: key, artist: meta.artist, title: meta.title, album: meta.album, year: meta.year,
            filePath: url.path, fileMtime: mtime,
            bpm: f.bpm, bpmConfidence: f.bpmConfidence, keyRoot: f.keyRoot, keyMode: f.keyMode,
            camelot: f.camelot, energy: f.energy, duration: f.durationSec,
            tags: nil, analyzedAt: isoFormatter.string(from: Date())
        )
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
