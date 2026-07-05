#if os(macOS)
import XCTest
@testable import RoonSageCore

/// The rolling weekly ListenBrainz families must collapse to one playlist each,
/// so the app + Qobuz don't accumulate a copy per week.
final class ListenBrainzCollapseTests: XCTestCase {

    private func pl(_ id: String, _ name: String, _ titles: [String]) -> DatabaseManager.ExternalPlaylist {
        DatabaseManager.ExternalPlaylist(
            externalID: "listenbrainz:\(id)", name: name,
            tracks: titles.map { TrackRecord(id: "", title: $0, artist: "A", album: nil) })
    }

    func testCollapsesWeeklyFamiliesKeepingNewest() {
        let input = [
            pl("y1", "Top Discoveries of 2023 for X", ["a"]),
            pl("y2", "Top Discoveries of 2024 for X", ["b"]),
            pl("we1", "Weekly Exploration for X, week of 2026-06-22 Mon", ["old-exp"]),
            pl("we2", "Weekly Exploration for X, week of 2026-06-29 Mon", ["new-exp"]),
            pl("wj1", "Weekly Jams for X, week of 2026-06-22 Mon", ["old-jam"]),
            pl("wj2", "Weekly Jams for X, week of 2026-06-29 Mon", ["new-jam"]),
        ]
        let out = RoonClient.collapseRecurringPlaylists(input)

        // 2 one-offs (unchanged) + 1 Weekly Jams + 1 Weekly Exploration = 4.
        XCTAssertEqual(out.count, 4)
        let byName = Dictionary(uniqueKeysWithValues: out.map { ($0.name, $0) })

        // Yearly one-offs pass through verbatim (distinct, not collapsed).
        XCTAssertNotNil(byName["Top Discoveries of 2023 for X"])
        XCTAssertNotNil(byName["Top Discoveries of 2024 for X"])

        // Weeklies collapse to a stable name + synthetic id, newest tracks.
        let jams = try! XCTUnwrap(byName["Weekly Jams"])
        XCTAssertEqual(jams.externalID, "listenbrainz:recurring:weekly-jams")
        XCTAssertEqual(jams.tracks.map(\.title), ["new-jam"], "newest week's tracks win")

        let exp = try! XCTUnwrap(byName["Weekly Exploration"])
        XCTAssertEqual(exp.externalID, "listenbrainz:recurring:weekly-exploration")
        XCTAssertEqual(exp.tracks.map(\.title), ["new-exp"])
    }

    func testOrderIndependentNewestWins() {
        // Newest listed FIRST — the max-date pick must still win regardless of order.
        let input = [
            pl("wj2", "Weekly Jams for X, week of 2026-07-06 Mon", ["newest"]),
            pl("wj1", "Weekly Jams for X, week of 2026-06-01 Mon", ["older"]),
        ]
        let out = RoonClient.collapseRecurringPlaylists(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.tracks.map(\.title), ["newest"])
    }

    func testNonRecurringUntouched() {
        let input = [pl("z", "Mijn eigen mix", ["x"])]
        let out = RoonClient.collapseRecurringPlaylists(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.name, "Mijn eigen mix")
        XCTAssertEqual(out.first?.externalID, "listenbrainz:z")
    }
}
#endif
