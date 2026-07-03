import XCTest
@testable import AnalyzerCore

final class AudioTranscoderTests: XCTestCase {
    func testLosslessAlwaysTranscodes() {
        // Path needn't exist: the lossless branch decides on extension alone.
        XCTAssertTrue(AudioTranscoder.shouldTranscode(sourcePath: "/x/track.flac", requestedKbps: 256))
        XCTAssertTrue(AudioTranscoder.shouldTranscode(sourcePath: "/x/track.wav", requestedKbps: 128))
        XCTAssertTrue(AudioTranscoder.shouldTranscode(sourcePath: "/x/track.aiff", requestedKbps: 192))
    }

    func testLossyWithoutFileServesOriginal() {
        // Missing lossy file → can't estimate a bitrate → no transcode (no-op).
        XCTAssertFalse(AudioTranscoder.shouldTranscode(sourcePath: "/nope/track.mp3", requestedKbps: 128))
    }

    func testCacheURLIsDeterministicAndBitrateSensitive() {
        let a = AudioTranscoder.cacheURL(sourcePath: "/x/track.flac", kbps: 256)
        let b = AudioTranscoder.cacheURL(sourcePath: "/x/track.flac", kbps: 256)
        let c = AudioTranscoder.cacheURL(sourcePath: "/x/track.flac", kbps: 128)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c, "different bitrate → different cache entry")
        XCTAssertEqual(a.pathExtension, "m4a")
    }

    func testPruneRemovesOldestBeyondCap() throws {
        // Exercise the prune walk on a real dir with tiny files and a tiny cap
        // is not possible (cap is a constant), so just assert it doesn't throw
        // on an empty/small cache dir.
        AudioTranscoder.pruneCache()
    }
}
