@testable import AnalyzerCore
import AudioAnalysis
import XCTest

/// Covers the pure helpers behind the `/audio` streaming endpoint (local
/// playback on the phone): Range parsing, content-type mapping, slice reads,
/// and the FeatureStore match-key → file-path resolution.
final class AudioStreamingTests: XCTestCase {

    // MARK: - Range parsing

    func testNoRangeIsFull() {
        XCTAssertEqual(AudioStreaming.parseRange(nil, fileSize: 1000), .full)
        XCTAssertEqual(AudioStreaming.parseRange("", fileSize: 1000), .full)
        XCTAssertEqual(AudioStreaming.parseRange("bytes=", fileSize: 1000), .full)
    }

    func testClosedRange() {
        XCTAssertEqual(AudioStreaming.parseRange("bytes=0-1023", fileSize: 5000),
                       .partial(start: 0, end: 1023))
        XCTAssertEqual(AudioStreaming.parseRange("bytes=100-199", fileSize: 5000),
                       .partial(start: 100, end: 199))
    }

    func testOpenEndedRangeClampsToLastByte() {
        XCTAssertEqual(AudioStreaming.parseRange("bytes=500-", fileSize: 1000),
                       .partial(start: 500, end: 999))
    }

    func testEndBeyondFileClampsToLastByte() {
        XCTAssertEqual(AudioStreaming.parseRange("bytes=0-99999", fileSize: 1000),
                       .partial(start: 0, end: 999))
    }

    func testSuffixRange() {
        XCTAssertEqual(AudioStreaming.parseRange("bytes=-200", fileSize: 1000),
                       .partial(start: 800, end: 999))
        // Suffix larger than the file → whole file.
        XCTAssertEqual(AudioStreaming.parseRange("bytes=-5000", fileSize: 1000),
                       .partial(start: 0, end: 999))
    }

    func testUnsatisfiableWhenStartPastEnd() {
        XCTAssertEqual(AudioStreaming.parseRange("bytes=2000-3000", fileSize: 1000),
                       .unsatisfiable)
        XCTAssertEqual(AudioStreaming.parseRange("bytes=0-0", fileSize: 0), .unsatisfiable)
    }

    func testReversedOrGarbageRangeDegradesToFull() {
        XCTAssertEqual(AudioStreaming.parseRange("bytes=900-100", fileSize: 1000), .full)
        XCTAssertEqual(AudioStreaming.parseRange("items=0-10", fileSize: 1000), .full)
        XCTAssertEqual(AudioStreaming.parseRange("bytes=abc-def", fileSize: 1000), .full)
    }

    func testFirstRangeOfMultiRangeWins() {
        XCTAssertEqual(AudioStreaming.parseRange("bytes=0-99,200-299", fileSize: 1000),
                       .partial(start: 0, end: 99))
    }

    // MARK: - Content type / extension

    func testContentTypes() {
        XCTAssertEqual(AudioStreaming.contentType(forPath: "/m/a.flac"), "audio/flac")
        XCTAssertEqual(AudioStreaming.contentType(forPath: "/m/a.MP3"), "audio/mpeg")
        XCTAssertEqual(AudioStreaming.contentType(forPath: "/m/a.m4a"), "audio/mp4")
        XCTAssertEqual(AudioStreaming.contentType(forPath: "/m/a.wav"), "audio/wav")
        XCTAssertEqual(AudioStreaming.contentType(forPath: "/m/a.xyz"), "application/octet-stream")
    }

    func testAllowedExtensions() {
        XCTAssertTrue(AudioStreaming.isAllowedExtension("FLAC"))
        XCTAssertTrue(AudioStreaming.isAllowedExtension("mp3"))
        XCTAssertFalse(AudioStreaming.isAllowedExtension("txt"))
        XCTAssertFalse(AudioStreaming.isAllowedExtension(""))
    }

    // MARK: - Slice reads

    func testReadSliceReturnsExactBytes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rs-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tone.bin")
        let payload = Data((0..<256).map { UInt8($0 & 0xff) })
        try payload.write(to: file)

        XCTAssertEqual(AudioStreaming.fileSize(path: file.path), 256)

        let head = AudioStreaming.readSlice(path: file.path, start: 0, end: 9)
        XCTAssertEqual(head, payload.subdata(in: 0..<10))

        let mid = AudioStreaming.readSlice(path: file.path, start: 100, end: 109)
        XCTAssertEqual(mid, payload.subdata(in: 100..<110))

        let tail = AudioStreaming.readSlice(path: file.path, start: 250, end: 255)
        XCTAssertEqual(tail, payload.subdata(in: 250..<256))
    }

    func testReadSliceMissingFileIsNil() {
        XCTAssertNil(AudioStreaming.readSlice(path: "/no/such/file.flac", start: 0, end: 10))
        XCTAssertNil(AudioStreaming.fileSize(path: "/no/such/file.flac"))
    }

    // MARK: - FeatureStore resolution

    func testFilePathResolution() throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("rs-fs-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let store = try FeatureStore(path: dbPath)
        let row = TrackFeatureRow(
            matchKey: "seed", artist: "Boards of Canada", title: "Roygbiv", album: "MHTRTC",
            year: 1998, filePath: "/Volumes/Music/BoC/Roygbiv.flac", fileMtime: 1,
            bpm: 110, bpmConfidence: 0.9, keyRoot: "C", keyMode: "major", camelot: "8B",
            energy: 0.5, duration: 130, tags: nil, analyzedAt: "now")
        try store.upsert(row)

        // Resolve by the current-scheme match key (what /features exports + the
        // client holds), not the arbitrary stored PK.
        let key = TrackIdentity.matchKey(artist: "Boards of Canada", album: "MHTRTC", title: "Roygbiv")
        XCTAssertEqual(store.filePath(forMatchKey: key), "/Volumes/Music/BoC/Roygbiv.flac")
        XCTAssertTrue(store.playableMatchKeys().contains(key))

        XCTAssertNil(store.filePath(forMatchKey: "definitely-not-present"))

        // (PERF-H1) The fallback map is memoized on the corpus signature; adding a
        // row must invalidate it so a newly-analysed track resolves via the map.
        let row2 = TrackFeatureRow(
            matchKey: "seed2", artist: "Aphex Twin", title: "Xtal", album: "SAW 85-92",
            year: 1992, filePath: "/Volumes/Music/AFX/Xtal.flac", fileMtime: 1,
            bpm: 100, bpmConfidence: 0.9, keyRoot: "A", keyMode: "minor", camelot: "8A",
            energy: 0.4, duration: 293, tags: nil, analyzedAt: "now")
        try store.upsert(row2)
        let key2 = TrackIdentity.matchKey(artist: "Aphex Twin", album: "SAW 85-92", title: "Xtal")
        XCTAssertEqual(store.filePath(forMatchKey: key2), "/Volumes/Music/AFX/Xtal.flac")
        XCTAssertTrue(store.playableMatchKeys().contains(key2))
        // The first track still resolves after the rebuild.
        XCTAssertEqual(store.filePath(forMatchKey: key), "/Volumes/Music/BoC/Roygbiv.flac")
    }
}
