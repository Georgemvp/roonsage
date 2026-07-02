import XCTest
@testable import RoonSageCore

/// Pins the pure LRC/lyrics parsing that drives karaoke mode, plus the discovery
/// cache's key hashing and the zone shuffle/repeat settings parsing.
final class LyricsParseTests: XCTestCase {

    // MARK: LRC timestamps

    func testParseStampMinutesSeconds() {
        XCTAssertEqual(LyricsService.parseStamp("00:12.00"), 12.0)
        XCTAssertEqual(LyricsService.parseStamp("01:05.50"), 65.5)
        XCTAssertEqual(LyricsService.parseStamp("02:00"), 120.0)
    }

    func testParseStampRejectsIDTags() {
        XCTAssertNil(LyricsService.parseStamp("ar:Some Artist"))
        XCTAssertNil(LyricsService.parseStamp("ti:A Title"))
    }

    // MARK: LRC body

    func testParseLRCBasicOrder() {
        let lrc = "[00:05.00]first\n[00:10.50]second\n[00:02.00]zeroth"
        let lines = LyricsService.parseLRC(lrc)
        XCTAssertEqual(lines.map(\.text), ["zeroth", "first", "second"])
        XCTAssertEqual(lines.map(\.time), [2.0, 5.0, 10.5])
    }

    func testParseLRCMultipleStampsPerLine() {
        let lines = LyricsService.parseLRC("[00:12.00][00:47.00] chorus")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map(\.text), ["chorus", "chorus"])
        XCTAssertEqual(lines.map(\.time), [12.0, 47.0])
    }

    func testParseLRCSkipsIDTagsButKeepsTimedLine() {
        let lrc = "[ar:Artist]\n[ti:Title]\n[00:05.00]real line"
        let lines = LyricsService.parseLRC(lrc)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "real line")
        XCTAssertEqual(lines.first?.time, 5.0)
    }

    // MARK: Record mapping

    func testParseInstrumental() {
        let l = LyricsService.parse(["instrumental": true])
        XCTAssertEqual(l?.isInstrumental, true)
        XCTAssertEqual(l?.hasContent, true)
    }

    func testParsePrefersSyncedButKeepsPlain() {
        let l = LyricsService.parse([
            "plainLyrics": "line one\nline two",
            "syncedLyrics": "[00:01.00]line one\n[00:03.00]line two",
        ])
        XCTAssertEqual(l?.synced?.count, 2)
        XCTAssertEqual(l?.plain, "line one\nline two")
    }

    func testParseEmptyRecordIsNil() {
        XCTAssertNil(LyricsService.parse([:]))
        XCTAssertNil(LyricsService.parse(["plainLyrics": "", "instrumental": false]))
    }

    // MARK: Discovery cache key hashing

    func testCacheKeyHashIsStableAndDistinct() {
        XCTAssertEqual(DiscoveryHTTPCache.fnv1a("mb.artist.radiohead"),
                       DiscoveryHTTPCache.fnv1a("mb.artist.radiohead"))
        XCTAssertNotEqual(DiscoveryHTTPCache.fnv1a("mb.artist.radiohead"),
                          DiscoveryHTTPCache.fnv1a("mb.artist.portishead"))
    }

    // MARK: Zone shuffle/repeat parsing (feeds the new Now Playing controls)

    func testZoneParsesShuffleAndLoopFromSettings() {
        let zone = Zone(from: [
            "zone_id": "z1", "display_name": "Woonkamer", "state": "playing",
            "settings": ["shuffle": true, "loop": "loop_one"],
        ])
        XCTAssertEqual(zone.shuffle, true)
        XCTAssertEqual(zone.loopMode, "loop_one")
    }

    func testZoneWithoutSettingsLeavesOptionsNil() {
        let zone = Zone(from: ["zone_id": "z2", "display_name": "Keuken", "state": "paused"])
        XCTAssertNil(zone.shuffle)
        XCTAssertNil(zone.loopMode)
    }
}
