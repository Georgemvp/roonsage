import AVFoundation
import Foundation

public enum AudioDecodeError: Error {
    case formatFailed
    case converterFailed
}

public struct DecodedAudio: Sendable {
    public let samples: [Float]      // mono
    public let sampleRate: Double
    public var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
}

/// Decodes any AVFoundation-supported file (FLAC/ALAC/AAC/MP3/WAV/AIFF on
/// modern macOS) to mono Float32 at a target analysis sample rate.
public struct AudioDecoder {

    public static func decode(url: URL, targetSampleRate: Double = 22050) throws -> DecodedAudio {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return DecodedAudio(samples: [], sampleRate: targetSampleRate) }

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw AudioDecodeError.converterFailed
        }

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount) else {
            throw AudioDecodeError.formatFailed
        }
        try file.read(into: inBuf)

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

        let n = Int(outBuf.frameLength)
        guard n > 0, let ch = outBuf.floatChannelData?[0] else {
            return DecodedAudio(samples: [], sampleRate: targetSampleRate)
        }
        return DecodedAudio(samples: Array(UnsafeBufferPointer(start: ch, count: n)), sampleRate: targetSampleRate)
    }
}
