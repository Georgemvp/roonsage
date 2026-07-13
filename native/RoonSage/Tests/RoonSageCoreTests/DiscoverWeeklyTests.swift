@testable import RoonSageCore
import XCTest

/// "Ontdek Wekelijks" — the library-first weekly discovery selection. These cover
/// the pure, testable primitives: seed selection (most-played), the recency
/// exclusion (what makes it discovery), the plan's cap/dedup/exclusion, and the
/// scheduler's due logic.
final class DiscoverWeeklyTests: XCTestCase {

    private func track(_ id: String, _ emb: [Float], artist: String, matchKey: String) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(
            id: id, title: id, artist: artist, album: "Al", imageKey: nil, matchKey: matchKey,
            bpm: 120, camelot: "8B", energy: 0.5, tags: [], embedding: emb)
    }

    // MARK: selectSeeds

    func testSelectSeedsTakesMostPlayedPresentInLibrary() {
        let lib = [track("t1", [1, 0, 0, 0], artist: "A", matchKey: "m1"),
                   track("t2", [0, 1, 0, 0], artist: "B", matchKey: "m2")]
        let byMK = Dictionary(lib.map { ($0.matchKey, $0) }, uniquingKeysWith: { a, _ in a })
        // m2 played more than m1; "mX" is played most but ISN'T in the library → dropped.
        let stats: [(matchKey: String, count: Int, lastPlayed: String)] = [
            ("m1", 3, ""), ("m2", 10, ""), ("mX", 99, "")]
        let seeds = DiscoverWeekly.selectSeeds(playStats: stats, byMatchKey: byMK, limit: 5)
        XCTAssertEqual(seeds.map(\.matchKey), ["m2", "m1"], "ordered by play count, library-only")
    }

    func testSelectSeedsRespectsLimit() {
        let lib = (0..<10).map { track("t\($0)", [Float($0), 1, 0, 0], artist: "A\($0)", matchKey: "m\($0)") }
        let byMK = Dictionary(lib.map { ($0.matchKey, $0) }, uniquingKeysWith: { a, _ in a })
        let stats = (0..<10).map { (matchKey: "m\($0)", count: 10 - $0, lastPlayed: "") }
        XCTAssertEqual(DiscoverWeekly.selectSeeds(playStats: stats, byMatchKey: byMK, limit: 3).count, 3)
    }

    /// A big, skewed library (counts 200…1, incl. 1000+-play "monopolists") must NOT
    /// hand back the same 40 anchors every week: a different ISO-week salt rotates a
    /// different loved set in, and the same salt stays deterministic.
    func testSelectSeedsRotatesWeeklyWithSalt() {
        let lib = (0..<200).map { track("t\($0)", [Float($0), 1, 0, 0], artist: "A\($0)", matchKey: "m\($0)") }
        let byMK = Dictionary(lib.map { ($0.matchKey, $0) }, uniquingKeysWith: { a, _ in a })
        // m0 is a 1000+-play monopolist; the rest fall off steeply.
        let stats = (0..<200).map { (matchKey: "m\($0)", count: $0 == 0 ? 1500 : 200 - $0, lastPlayed: "") }

        let w27 = DiscoverWeekly.selectSeeds(playStats: stats, byMatchKey: byMK, limit: 40, salt: "2026-W27")
        let w28 = DiscoverWeekly.selectSeeds(playStats: stats, byMatchKey: byMK, limit: 40, salt: "2026-W28")
        XCTAssertEqual(w27.count, 40)
        XCTAssertEqual(w28.count, 40)
        XCTAssertNotEqual(Set(w27.map(\.id)), Set(w28.map(\.id)), "different weeks anchor a different loved set")

        // Deterministic within a week (same salt → same seeds).
        let w27again = DiscoverWeekly.selectSeeds(playStats: stats, byMatchKey: byMK, limit: 40, salt: "2026-W27")
        XCTAssertEqual(w27.map(\.id), w27again.map(\.id), "same ISO week reproduces the same seeds")

        // Rotation pulls tracks beyond the raw top-40-by-count into the anchors.
        let rawTop40 = Set((0..<40).map { "m\($0)" })
        XCTAssertFalse(Set(w27.map(\.id)).isSubset(of: rawTop40), "seeds aren't just the all-time top 40")
    }

    /// Log-dampening: with no salt the order follows log(1+count)·recency, so a
    /// 1000-play track leads a 30-play one but not by the raw ~33× ratio — the pool
    /// of realistic seeds is wide, not dominated by one monopolist.
    func testSelectSeedsLogDampensPlayCounts() {
        let lib = [track("t1", [1, 0, 0, 0], artist: "A", matchKey: "m1"),
                   track("t2", [0, 1, 0, 0], artist: "B", matchKey: "m2")]
        let byMK = Dictionary(lib.map { ($0.matchKey, $0) }, uniquingKeysWith: { a, _ in a })
        let stats: [(matchKey: String, count: Int, lastPlayed: String)] = [("m1", 1000, ""), ("m2", 30, "")]
        // Heaviest-first order preserved (no salt), but via the dampened weight.
        let seeds = DiscoverWeekly.selectSeeds(playStats: stats, byMatchKey: byMK, limit: 2)
        XCTAssertEqual(seeds.map(\.matchKey), ["m1", "m2"])
        let ratio = SonicDNA.playWeight(count: 1000, lastPlayed: "") / SonicDNA.playWeight(count: 30, lastPlayed: "")
        XCTAssertLessThan(ratio, 3.0, "log-dampened weight ratio « the raw 33× count ratio")
    }

    // MARK: recentlyPlayedKeys

    func testRecentlyPlayedKeysWindow() {
        let now = Date()
        let iso = ISO8601DateFormatter()
        let stats: [(matchKey: String, count: Int, lastPlayed: String)] = [
            ("recent", 1, iso.string(from: now.addingTimeInterval(-2 * 86_400))),   // 2 days ago
            ("old",    1, iso.string(from: now.addingTimeInterval(-40 * 86_400))),  // 40 days ago
            ("bad",    1, "")]                                                        // unparseable
        let keys = DiscoverWeekly.recentlyPlayedKeys(playStats: stats, withinDays: 30, now: now)
        XCTAssertTrue(keys.contains("recent"))
        XCTAssertFalse(keys.contains("old"), "outside the window is not excluded")
        XCTAssertFalse(keys.contains("bad"), "unparseable timestamp excludes nothing")
    }

    func testRecentlyPlayedKeysZeroDaysExcludesNothing() {
        let now = Date()
        let stats: [(matchKey: String, count: Int, lastPlayed: String)] = [
            ("a", 1, ISO8601DateFormatter().string(from: now))]
        XCTAssertTrue(DiscoverWeekly.recentlyPlayedKeys(playStats: stats, withinDays: 0, now: now).isEmpty)
    }

    // MARK: plan

    /// One seed + 15 unique-artist candidates; `c1` and `c2` are recently played and
    /// `c3` is disliked — none may survive into the weekly, and the seed itself never does.
    private func planFixture() -> (seed: DatabaseManager.SonicTrack, lib: [DatabaseManager.SonicTrack], index: VectorIndex) {
        let seed = track("seed", [1, 0, 0, 0], artist: "Seed", matchKey: "seed")
        var lib = [seed]
        for i in 1...15 {
            let f = Float(i)
            let emb = [1, f * 0.05, Float(i % 3) * 0.04, 0]
            lib.append(track("c\(i)", emb, artist: "Artist\(i)", matchKey: "c\(i)"))
        }
        return (seed, lib, VectorIndex(tracks: lib)!)
    }

    func testPlanExcludesRecentAndDislikedAndSeed() {
        let (seed, lib, index) = planFixture()
        let opts = DiscoverWeekly.Options(trackCount: 6, adventurousness: 0.5, exclusionDays: 30, maxPerArtist: 2)
        let out = DiscoverWeekly.plan(
            seeds: [seed], library: lib, index: index,
            recentlyPlayedKeys: ["c1", "c2"], disliked: ["c3"], likedKeys: [],
            knownArtists: [], tasteVector: nil, options: opts, salt: "2026-W27")

        let keys = Set(out.map(\.matchKey))
        XCTAssertFalse(keys.contains("seed"), "the seed is never in its own weekly")
        XCTAssertFalse(keys.contains("c1"), "recently played excluded")
        XCTAssertFalse(keys.contains("c2"), "recently played excluded")
        XCTAssertFalse(keys.contains("c3"), "disliked excluded")
        XCTAssertFalse(out.isEmpty)
    }

    func testPlanCapsToTrackCountAndDedupes() {
        let (seed, lib, index) = planFixture()
        let opts = DiscoverWeekly.Options(trackCount: 5, adventurousness: 0.5, exclusionDays: 30, maxPerArtist: 2)
        let out = DiscoverWeekly.plan(
            seeds: [seed], library: lib, index: index,
            recentlyPlayedKeys: [], disliked: [], likedKeys: [],
            knownArtists: [], tasteVector: nil, options: opts, salt: "2026-W27")
        XCTAssertEqual(out.count, 5, "capped to trackCount")
        XCTAssertEqual(Set(out.map(\.matchKey)).count, out.count, "no duplicate content")
    }

    func testPlanIsDeterministicPerSalt() {
        let (seed, lib, index) = planFixture()
        let opts = DiscoverWeekly.Options(trackCount: 6, adventurousness: 0.5, exclusionDays: 30, maxPerArtist: 2)
        func run() -> [String] {
            DiscoverWeekly.plan(
                seeds: [seed], library: lib, index: index,
                recentlyPlayedKeys: [], disliked: [], likedKeys: [],
                knownArtists: [], tasteVector: nil, options: opts, salt: "2026-W27").map(\.matchKey)
        }
        XCTAssertEqual(run(), run(), "same inputs + salt → same weekly")
    }

    func testPlanEmptyWithoutSeeds() {
        let (_, lib, index) = planFixture()
        let opts = DiscoverWeekly.Options()
        XCTAssertTrue(DiscoverWeekly.plan(
            seeds: [], library: lib, index: index, recentlyPlayedKeys: [], disliked: [],
            likedKeys: [], knownArtists: [], tasteVector: nil, options: opts, salt: "x").isEmpty)
    }

    // MARK: cross-feature de-dup keys

    func testSurfacedKeysExposeAlbumsAndTracksForDedup() {
        let pl = DiscoverWeeklyPlaylist(
            weekKey: "2026-W27", generatedAt: "", title: "t", description: "d",
            imageKey: nil, seedMatchKeys: [],
            tracks: [
                DiscoverWeeklyTrack(id: "1", title: "Song A", artist: "Artist X", album: "Album One", notInLibrary: false),
                DiscoverWeeklyTrack(id: "2", title: "Song B", artist: nil, album: nil, notInLibrary: true),
            ])
        XCTAssertEqual(pl.albumKeysSurfaced, ["album one"], "album names are lower-cased; nil album ignored")
        XCTAssertTrue(pl.trackKeysSurfaced.contains("song a|artist x"))
        XCTAssertTrue(pl.trackKeysSurfaced.contains("song b|"), "nil artist → empty artist half")
    }

    // MARK: due logic

    func testDueWhenNoneExists() {
        XCTAssertTrue(RoonClient.discoverWeeklyDue(current: nil, intervalDays: 7))
    }

    func testDueAfterIntervalElapsed() {
        let now = Date()
        let old = DiscoverWeeklyPlaylist(
            weekKey: "2026-W20",
            generatedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-8 * 86_400)),
            title: "t", description: "d", imageKey: nil, seedMatchKeys: [], tracks: [])
        XCTAssertTrue(RoonClient.discoverWeeklyDue(current: old, intervalDays: 7, now: now))
    }

    func testNotDueWithinInterval() {
        let now = Date()
        let recent = DiscoverWeeklyPlaylist(
            weekKey: "2026-W27",
            generatedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-3 * 86_400)),
            title: "t", description: "d", imageKey: nil, seedMatchKeys: [], tracks: [])
        XCTAssertFalse(RoonClient.discoverWeeklyDue(current: recent, intervalDays: 7, now: now))
    }
}
