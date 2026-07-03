import AVFoundation
import Foundation

/// On-the-fly AAC transcoding for the `/audio` endpoint (LMS-audit §1.2):
/// streaming FLAC over ZeroTier on cellular is heavy and expensive, so remote
/// clients can request `format=aac&bitrate=<kbps>` and get an M4A instead.
///
/// Design choices (deliberately different from LMS's ffmpeg pipe):
///  - **Whole-file to a disk cache, then serve with Range.** AVPlayer seeks by
///    Range requests; a fully-written M4A with a real Content-Length seeks
///    natively, so no `-ss` offset re-request protocol is needed.
///  - **Smart no-op** (`shouldTranscode`): an already-lossy source at or below
///    the requested bitrate is served as-is — never burn CPU to make audio
///    worse. Lossless sources always transcode when asked.
///  - **Single-flight per (file, bitrate)** so a scrubbing client doesn't kick
///    off parallel encodes of the same track; LRU cache capped at 500 MB.
public actor AudioTranscoder {
    public static let shared = AudioTranscoder()

    static let lossyExtensions: Set<String> = ["mp3", "m4a", "aac", "ogg", "opus"]
    static let cacheCap: Int64 = 500 * 1024 * 1024

    private var inFlight: [String: Task<URL?, Never>] = [:]

    /// Whether a transcode is worth it: lossless always; lossy only when its
    /// estimated bitrate meaningfully exceeds the request (15% headroom so a
    /// 260 kbps MP3 isn't "transcoded" to 256).
    public static func shouldTranscode(sourcePath: String, requestedKbps: Int) -> Bool {
        let ext = (sourcePath as NSString).pathExtension.lowercased()
        guard lossyExtensions.contains(ext) else { return true }   // lossless → yes
        guard let size = try? FileManager.default.attributesOfItem(atPath: sourcePath)[.size] as? Int64,
              size > 0 else { return false }
        let asset = AVURLAsset(url: URL(fileURLWithPath: sourcePath))
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 1 else { return false }  // unknown → serve original
        let estKbps = Double(size) * 8 / seconds / 1000
        return estKbps > Double(requestedKbps) * 1.15
    }

    /// Cached (or freshly encoded) M4A for this source at this bitrate.
    /// nil = encode failed; callers fall back to the original file.
    public func transcoded(sourcePath: String, kbps: Int) async -> URL? {
        let dest = Self.cacheURL(sourcePath: sourcePath, kbps: kbps)
        if FileManager.default.fileExists(atPath: dest.path) {
            // Touch for LRU.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
            return dest
        }
        let key = dest.lastPathComponent
        if let running = inFlight[key] { return await running.value }
        let task = Task<URL?, Never>.detached(priority: .userInitiated) {
            let ok = await Self.encode(source: URL(fileURLWithPath: sourcePath), dest: dest, kbps: kbps)
            if ok { Self.pruneCache() }
            return ok ? dest : nil
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    // MARK: - Cache

    static func cacheDir() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("roonsage-transcode", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheURL(sourcePath: String, kbps: Int) -> URL {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: sourcePath)[.modificationDate] as? Date)
            .map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        var h: UInt64 = 0xcbf29ce484222325
        for b in "\(sourcePath)\u{1f}\(mtime)\u{1f}\(kbps)".utf8 {
            h ^= UInt64(b); h &*= 0x100000001b3
        }
        return cacheDir().appendingPathComponent(String(h, radix: 36) + ".m4a")
    }

    /// LRU-ish prune: drop oldest-touched files until under the cap.
    static func pruneCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDir(), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries: [(url: URL, size: Int64, date: Date)] = files.compactMap { url in
            guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = vals.fileSize else { return nil }
            return (url, Int64(size), vals.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > cacheCap else { return }
        entries.sort { $0.date < $1.date }
        for e in entries {
            guard total > cacheCap else { break }
            try? fm.removeItem(at: e.url)
            total -= e.size
        }
    }

    // MARK: - Encoding (AVAssetReader → AVAssetWriter, PCM → AAC)

    static func encode(source: URL, dest: URL, kbps: Int) async -> Bool {
        let asset = AVURLAsset(url: source)
        guard let srcTrack = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return false }
        let tmp = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)
        guard let writer = try? AVAssetWriter(outputURL: tmp, fileType: .m4a) else { return false }

        let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM]
        let readerOutput = AVAssetReaderTrackOutput(track: srcTrack, outputSettings: pcm)
        guard reader.canAdd(readerOutput) else { return false }
        reader.add(readerOutput)

        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: max(64, min(320, kbps)) * 1000,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { return false }
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "roonsage.transcode")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let buffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(buffer)
                    } else {
                        writerInput.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
        await writer.finishWriting()
        reader.cancelReading()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
            return true
        } catch {
            return false
        }
    }
}
