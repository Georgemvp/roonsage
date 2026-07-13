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

        // Chunked read+convert: a whole hi-res track no longer needs one giant
        // input buffer (a 20-min 192 kHz stereo file would be ~1.8 GB one-shot).
        // The converter keeps its resample state across chunks, so the output
        // matches the previous single-shot path.
        let chunkFrames: AVAudioFrameCount = 1 << 18   // input frames per read (~1.4-6 s; a few MB)
        var remaining = framesToRead
        if startFrame > 0 { file.framePosition = startFrame }

        let ratio = targetSampleRate / inFormat.sampleRate
        var samples = [Float]()
        samples.reserveCapacity(Int(Double(framesToRead) * ratio) + 8192)
        let outCapacity = AVAudioFrameCount(Double(chunkFrames) * ratio) + 8192
        var readError: Error?

        // chunkFrames=4: framesToRead=0 -> 0 reads; 3 -> read 3, EOS; 9 -> 4+4+1, EOS.
        conversion: while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
                throw AudioDecodeError.formatFailed
            }
            var convErr: NSError?
            let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
                guard remaining > 0, readError == nil else { outStatus.pointee = .endOfStream; return nil }
                let toRead = min(chunkFrames, remaining)
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: toRead) else {
                    readError = AudioDecodeError.formatFailed
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do { try file.read(into: inBuf, frameCount: toRead) } catch {
                    readError = error
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard inBuf.frameLength > 0 else { remaining = 0; outStatus.pointee = .endOfStream; return nil }
                remaining -= min(remaining, inBuf.frameLength)   // min() guards UInt32 underflow
                outStatus.pointee = .haveData
                return inBuf
            }
            if let convErr { throw convErr }
            if let readError { throw readError }
            let produced = Int(outBuf.frameLength)
            if produced > 0, let ch = outBuf.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: produced))
            }
            switch status {
            case .endOfStream, .error: break conversion
            default: if produced == 0 { break conversion }   // defensive: no progress
            }
        }

        let fullDuration = Double(totalFrames) / inFormat.sampleRate
        return DecodedAudio(samples: samples, sampleRate: targetSampleRate, fullDurationSec: fullDuration)
    }
}
