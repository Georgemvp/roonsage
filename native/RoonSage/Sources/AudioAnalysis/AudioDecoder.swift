import AVFoundation
import Foundation

public enum AudioDecodeError: Error {
    case formatFailed
    case converterFailed
}

public struct DecodedAudio: Sendable {
    public let samples: [Float]      // mono (possibly an excerpt)
    public let sampleRate: Double
    public var fullDurationSec: Double = 0   // duration of the WHOLE track
    public var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
}

/// Decodes any AVFoundation-supported file (FLAC/ALAC/AAC/MP3/WAV/AIFF on
/// modern macOS) to mono Float32 at a target analysis sample rate.
public struct AudioDecoder {

    /// Decode (optionally just an excerpt) to mono Float32 at `targetSampleRate`.
    /// `maxSeconds > 0` reads only a bounded segment starting at `startFraction`
    /// of the track — far less I/O on slow drives, and representative for
    /// BPM/key/energy. `startFraction` is clamped so the window fits.
    public static func decode(
        url: URL,
        targetSampleRate: Double = 22050,
        maxSeconds: Double = 0,
        startFraction: Double = 0
    ) throws -> DecodedAudio {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return DecodedAudio(samples: [], sampleRate: targetSampleRate) }

        var startFrame: AVAudioFramePosition = 0
        var framesToRead = totalFrames
        if maxSeconds > 0 {
            let want = AVAudioFrameCount(maxSeconds * inFormat.sampleRate)
            if want < totalFrames {
                framesToRead = want
                let raw = AVAudioFramePosition(Double(totalFrames) * max(0, min(1, startFraction)))
                startFrame = max(0, min(raw, AVAudioFramePosition(totalFrames - want)))
            }
        }

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw AudioDecodeError.converterFailed
        }

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: framesToRead) else {
            throw AudioDecodeError.formatFailed
        }
        if startFrame > 0 { file.framePosition = startFrame }
        try file.read(into: inBuf, frameCount: framesToRead)
        let frameCount = framesToRead

        let ratio = targetSampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 8192
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw AudioDecodeError.formatFailed
        }

        var fed = false
        var convErr: NSError?
        _ = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if let convErr { throw convErr }

        let fullDuration = Double(totalFrames) / inFormat.sampleRate
        let n = Int(outBuf.frameLength)
        guard n > 0, let ch = outBuf.floatChannelData?[0] else {
            return DecodedAudio(samples: [], sampleRate: targetSampleRate, fullDurationSec: fullDuration)
        }
        return DecodedAudio(samples: Array(UnsafeBufferPointer(start: ch, count: n)),
                            sampleRate: targetSampleRate, fullDurationSec: fullDuration)
    }
}
