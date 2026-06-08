import AudioAnalysis
import Foundation

/// Walks a music directory, analyzes new/changed files concurrently, and stores
/// the results. Resumable: files already analyzed (same path + mtime) are skipped.
struct LibraryWalker {
    static let audioExtensions: Set<String> = ["flac", "m4a", "mp3", "wav", "aiff", "aif", "alac", "aac"]

    let store: FeatureStore
    let concurrency: Int

    init(store: FeatureStore, concurrency: Int = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)) {
        self.store = store
        self.concurrency = concurrency
    }

    func run(musicDir: String) async {
        let root = URL(fileURLWithPath: musicDir)
        print("Scanning \(root.path) …")
        let files = Self.findAudioFiles(root)
        print("Found \(files.count) audio files. Analyzing with \(concurrency) workers (resumable)…")

        let pending = files.filter { url in
            guard let mtime = Self.mtime(url) else { return true }
            return !store.isAnalyzed(path: url.path, mtime: mtime)
        }
        print("\(files.count - pending.count) already analyzed, \(pending.count) to do.")

        let isoFormatter = ISO8601DateFormatter()
        var done = 0
        var failed = 0
        let total = pending.count
        let t0 = Date()

        var index = 0
        await withTaskGroup(of: TrackFeatureRow?.self) { group in
            func submit(_ url: URL) {
                group.addTask {
                    Self.analyzeFile(url, isoFormatter: isoFormatter)
                }
            }
            // Prime the pool.
            while index < pending.count, index < concurrency {
                submit(pending[index]); index += 1
            }
            while let result = await group.next() {
                if let row = result {
                    try? store.upsert(row)
                    done += 1
                } else {
                    failed += 1
                }
                let processed = done + failed
                if processed % 50 == 0 || processed == total {
                    let rate = Double(processed) / max(0.001, Date().timeIntervalSince(t0))
                    let eta = rate > 0 ? Double(total - processed) / rate : 0
                    print(String(format: "  %d/%d  (%.1f/s, ETA %.0fs, %d failed)", processed, total, rate, eta, failed))
                }
                if index < pending.count { submit(pending[index]); index += 1 }
            }
        }
        print("Done. \(done) analyzed, \(failed) failed. Store now holds \(store.count()) tracks.")
    }

    private static func analyzeFile(_ url: URL, isoFormatter: ISO8601DateFormatter) -> TrackFeatureRow? {
        guard let mtime = mtime(url) else { return nil }
        let meta = MetadataReader.read(url: url)
        guard let features = try? AudioAnalyzer.analyze(url: url) else { return nil }
        let key = TrackIdentity.matchKey(artist: meta.artist, album: meta.album, title: meta.title)
        guard !key.replacingOccurrences(of: "\u{1f}", with: "").isEmpty else { return nil }
        return TrackFeatureRow(
            matchKey: key, artist: meta.artist, title: meta.title, album: meta.album, year: meta.year,
            filePath: url.path, fileMtime: mtime,
            bpm: features.bpm, bpmConfidence: features.bpmConfidence,
            keyRoot: features.keyRoot, keyMode: features.keyMode, camelot: features.camelot,
            energy: features.energy, duration: features.durationSec,
            tags: nil, analyzedAt: isoFormatter.string(from: Date())
        )
    }

    static func mtime(_ url: URL) -> Double? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970
    }

    static func findAudioFiles(_ root: URL) -> [URL] {
        var result: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in en {
            if audioExtensions.contains(url.pathExtension.lowercased()) { result.append(url) }
        }
        return result
    }
}
