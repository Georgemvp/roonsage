@testable import RoonSageCore
import XCTest

/// Pure mood-artist ranking (F12a): mean mood score per artist over owned/scored
/// tracks, the min-tracks floor, case-insensitivity, and the empty-mood fallback.
final class MoodSeedingTests: XCTestCase {

    private func t(_ artist: String?, _ moods: [String: Float]) -> MoodSeeding.TrackMoodFacts {
        .init(artist: artist, moods: moods)
    }

    func testRanksByMeanScoreDescending() {
        let tracks = [
            t("A", ["sad": 0.9]), t("A", ["sad": 0.7]),   // mean 0.8
            t("B", ["sad": 0.5]), t("B", ["sad": 0.5]),   // mean 0.5
        ]
        let result = MoodSeeding.topArtists(tracks, mood: "sad", limit: 10)
        XCTAssertEqual(result, ["A", "B"])
    }

    func testMinTracksFloorExcludesOneOffs() {
        let tracks = [
            t("Loner", ["sad": 1.0]),                      // only 1 scored track
            t("Steady", ["sad": 0.4]), t("Steady", ["sad": 0.6]),
        ]
        let result = MoodSeeding.topArtists(tracks, mood: "sad", limit: 10, minTracks: 2)
        XCTAssertEqual(result, ["Steady"])
    }

    func testCaseInsensitiveMoodAndArtistGrouping() {
        let tracks = [t("Radiohead", ["SAD": 0.8]), t("radiohead", ["sad": 0.6])]
        let result = MoodSeeding.topArtists(tracks, mood: "Sad", limit: 10, minTracks: 2)
        XCTAssertEqual(result, ["Radiohead"])   // groups under first-seen display case
    }

    func testUnknownMoodReturnsEmpty() {
        let tracks = [t("A", ["happy": 0.9]), t("A", ["happy": 0.9])]
        XCTAssertEqual(MoodSeeding.topArtists(tracks, mood: "nonexistent", limit: 10), [])
    }

    func testBlankMoodReturnsEmpty() {
        let tracks = [t("A", ["happy": 0.9])]
        XCTAssertEqual(MoodSeeding.topArtists(tracks, mood: "  ", limit: 10), [])
    }

    func testTracksWithoutArtistOrScoreAreIgnored() {
        let tracks = [t(nil, ["sad": 0.9]), t("A", [:]), t("A", ["happy": 0.9])]
        XCTAssertEqual(MoodSeeding.topArtists(tracks, mood: "sad", limit: 10, minTracks: 1), [])
    }

    func testLimitCaps() {
        let tracks = (0..<5).flatMap { i in
            [t("Artist\(i)", ["party": 1.0]), t("Artist\(i)", ["party": 1.0])]
        }
        XCTAssertEqual(MoodSeeding.topArtists(tracks, mood: "party", limit: 3, minTracks: 2).count, 3)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(MoodSeeding.topArtists([], mood: "sad", limit: 10), [])
    }
}
