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

    func testGenreBucketsUseRoonGenresAndFloor() {
        var lib: [DatabaseManager.SonicTrack] = []
        var genres: [String: Set<String>] = [:]
        for i in 0..<10  { lib.append(st(i)); genres["t\(i)"] = ["Rock"] }            // qualifies
        for i in 100..<109 { lib.append(st(i)); genres["t\(i)"] = ["Jazz"] }          // qualifies (9)
        for i in 200..<205 { lib.append(st(i)); genres["t\(i)"] = ["Pop"] }           // below the 8-track floor
        // Analyzer tags must NOT create genre buckets — only Roon genres count.
        for i in 300..<312 { lib.append(st(i, tags: ["peak-time", "high-energy"])) }

        let buckets = RoonClient.buildBuckets(
            category: .genre, lib: lib, genres: genres, years: [:], disliked: [], daySeed: "test")

        XCTAssertEqual(Set(buckets.map(\.label)), ["Rock", "Jazz"])
        let rock = buckets.first { $0.label == "Rock" }
        XCTAssertEqual(rock?.trackCount, 10)
        XCTAssertFalse(rock?.seedIds.isEmpty ?? true)
        XCTAssertEqual(rock?.id, "genre:rock")
    }

    // MARK: Mood

    func testMoodBucketsByDominantMood() {
        var lib: [DatabaseManager.SonicTrack] = []
        // Gekalibreerde toewijzing (gap G): elk cluster landt op het label waar
        // het — t.o.v. de bibliotheekverdeling — bovengemiddeld op scoort, ook
        // onder een absolute 0.5. De derde groep (sad 0.2 op een sad-basislijn
        // van ~0.14) is de relatief sadste muziek van deze bibliotheek en
        // krijgt dus een station; de oude absolute 0.3-floor sloot hem uit.
        lib += (0..<10).map { st($0, moods: ["happy": 0.42, "sad": 0.1]) }
        lib += (100..<109).map { st($0, moods: ["party": 0.38, "relaxed": 0.2]) }
        lib += (200..<208).map { st($0, moods: ["sad": 0.2, "happy": 0.15]) }

        let buckets = RoonClient.buildBuckets(
            category: .mood, lib: lib, genres: [:], years: [:], disliked: [], daySeed: "test")

        XCTAssertEqual(Set(buckets.map(\.label)), ["Melancholisch", "Vrolijk", "Feestelijk"])
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
