@testable import RoonSageCore
import XCTest

/// Radio categories: the pure `buildBuckets` slicer for genre / mood / activity /
/// decade. (Artist radios keep their own seed logic, tested via capForPlaylist.)
final class RadioCategoryTests: XCTestCase {

    private func st(
        _ i: Int, tags: [String] = [], moods: [String: Float] = [:],
        energy: Double? = nil, bpm: Double? = nil, matchKey: String? = nil
    ) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(
            id: "t\(i)", title: "T\(i)", artist: "A\(i)", album: nil, imageKey: nil,
            matchKey: matchKey ?? "m\(i)", bpm: bpm, camelot: "", energy: energy,
            tags: tags, moods: moods)
    }

    // MARK: Genre

    func testGenreBucketsDropUnderfilledAndUmbrella() {
        var lib: [DatabaseManager.SonicTrack] = []
        lib += (0..<10).map { st($0, tags: ["rock"]) }          // qualifies
        lib += (100..<109).map { st($0, tags: ["jazz"]) }       // qualifies (9)
        lib += (200..<205).map { st($0, tags: ["pop"]) }        // below the 8-track floor
        lib += (300..<312).map { st($0) }                       // untagged filler

        let buckets = RoonClient.buildBuckets(
            category: .genre, lib: lib, genres: [:], years: [:], disliked: [], daySeed: "test")

        XCTAssertEqual(Set(buckets.map(\.label)), ["Rock", "Jazz"])
        let rock = buckets.first { $0.label == "Rock" }
        XCTAssertEqual(rock?.trackCount, 10)
        XCTAssertFalse(rock?.seedIds.isEmpty ?? true)
        XCTAssertTrue(rock?.id == "genre:rock")
    }

    // MARK: Mood

    func testMoodBucketsKeepStrongMoodsOnly() {
        var lib: [DatabaseManager.SonicTrack] = []
        lib += (0..<10).map { st($0, moods: ["happy": 0.8]) }
        lib += (100..<109).map { st($0, moods: ["energetic": 0.6]) }
        lib += (200..<208).map { st($0, moods: ["sad": 0.3]) }   // below the 0.5 threshold

        let buckets = RoonClient.buildBuckets(
            category: .mood, lib: lib, genres: [:], years: [:], disliked: [], daySeed: "test")

        XCTAssertEqual(Set(buckets.map(\.label)), ["Vrolijk", "Energiek"])
    }

    // MARK: Activity

    func testActivityBucketsMatchEnergyAndTempo() {
        var lib: [DatabaseManager.SonicTrack] = []
        lib += (0..<10).map { st($0, energy: 0.85, bpm: 130) }   // workout / energiek / onderweg
        lib += (100..<110).map { st($0, energy: 0.3, bpm: 90) }  // chillen / focus

        let buckets = RoonClient.buildBuckets(
            category: .activity, lib: lib, genres: [:], years: [:], disliked: [], daySeed: "test")
        let labels = Set(buckets.map(\.label))

        XCTAssertTrue(labels.contains("Workout"))
        XCTAssertTrue(labels.contains("Chillen"))
        XCTAssertEqual(buckets.first { $0.label == "Workout" }?.trackCount, 10)
    }

    // MARK: Decade

    func testDecadeBucketsNewestFirstAndFloored() {
        var lib: [DatabaseManager.SonicTrack] = []
        var years: [String: Int] = [:]
        for i in 0..<10 { lib.append(st(i, matchKey: "k80_\(i)")); years["k80_\(i)"] = 1985 }
        for i in 0..<9  { lib.append(st(100 + i, matchKey: "k90_\(i)")); years["k90_\(i)"] = 1995 }
        for i in 0..<5  { lib.append(st(200 + i, matchKey: "k00_\(i)")); years["k00_\(i)"] = 2005 } // floored out

        let buckets = RoonClient.buildBuckets(
            category: .decade, lib: lib, genres: [:], years: years, disliked: [], daySeed: "test")

        XCTAssertEqual(buckets.map(\.label), ["Jaren 90", "Jaren 80"])  // newest first
    }

    // MARK: Daypart rotation

    func testCurrentDaypartByHour() {
        XCTAssertEqual(RoonClient.currentDaypart(hour: 6), .ochtend)
        XCTAssertEqual(RoonClient.currentDaypart(hour: 9), .ochtend)
        XCTAssertEqual(RoonClient.currentDaypart(hour: 12), .middag)
        XCTAssertEqual(RoonClient.currentDaypart(hour: 17), .middag)
        XCTAssertEqual(RoonClient.currentDaypart(hour: 18), .avond)
        XCTAssertEqual(RoonClient.currentDaypart(hour: 23), .avond)
        XCTAssertEqual(RoonClient.currentDaypart(hour: 0), .nacht)
        XCTAssertEqual(RoonClient.currentDaypart(hour: 5), .nacht)
    }

    func testDaypartCategoryMapping() {
        XCTAssertEqual(RoonClient.daypartCategory(.ochtend), .activity)
        XCTAssertEqual(RoonClient.daypartCategory(.middag), .genre)
        XCTAssertEqual(RoonClient.daypartCategory(.avond), .mood)
        XCTAssertEqual(RoonClient.daypartCategory(.nacht), .decade)
    }

    func testMorningIsCalmOthersDefault() {
        XCTAssertEqual(RoonClient.daypartRestrictKeys(.ochtend), ["focus", "lounge", "chillen"])
        XCTAssertNil(RoonClient.daypartRestrictKeys(.middag))
        XCTAssertNil(RoonClient.daypartRestrictKeys(.avond))
        XCTAssertNil(RoonClient.daypartRestrictKeys(.nacht))
    }
}
