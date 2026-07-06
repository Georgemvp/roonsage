import XCTest
@testable import RoonSageCore

/// Pure-logic tests for user-composed radios: the combined facet gate
/// (AND across facets, OR within), seed union, relaxation, and the config's
/// JSON round-trip (facet arrays as snake_case columns/keys).
final class CustomRadioTests: XCTestCase {

    private func track(_ id: String, artist: String, energy: Double = 0.5,
                       moods: [String: Float] = [:], matchKey: String? = nil)
        -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(id: id, title: id, artist: artist, album: nil, imageKey: nil,
                                   matchKey: matchKey ?? id, bpm: 120, camelot: "8A",
                                   energy: energy, tags: [], moods: moods)
    }

    private func config(genres: [String] = [], moods: [String] = [], activities: [String] = [],
                        decades: [Int] = [], artists: [String] = [], trackKeys: [String] = [])
        -> RadioConfig {
        RadioConfig(name: "Test", artists: artists, trackKeys: trackKeys,
                    genres: genres, moods: moods, activities: activities, decades: decades)
    }

    // MARK: Combined gate

    func testGateAndsAcrossFacets() {
        let cfg = config(genres: ["house"], moods: ["happy"])
        let a = track("a", artist: "A", moods: ["happy": 0.6, "sad": 0.1])   // house + happy
        let b = track("b", artist: "B", moods: ["sad": 0.6, "happy": 0.1])   // house + sad
        let c = track("c", artist: "C", moods: ["happy": 0.6])               // techno + happy
        let genres = ["a": Set(["house"]), "b": Set(["house"]), "c": Set(["techno"])]
        guard let gate = RoonClient.customGate(cfg: cfg, genres: genres, years: [:], calibration: nil) else {
            return XCTFail("expected a gate for genre+mood config")
        }
        XCTAssertTrue(gate(a), "house + happy passes both facets")
        XCTAssertFalse(gate(b), "sad fails the mood facet")
        XCTAssertFalse(gate(c), "techno fails the genre facet")
    }

    func testGateOrsWithinAFacet() {
        let cfg = config(genres: ["house", "techno"])
        let house = track("h", artist: "A")
        let techno = track("t", artist: "B")
        let jazz = track("j", artist: "C")
        let genres = ["h": Set(["house"]), "t": Set(["techno"]), "j": Set(["jazz"])]
        guard let gate = RoonClient.customGate(cfg: cfg, genres: genres, years: [:], calibration: nil) else {
            return XCTFail("expected a genre gate")
        }
        XCTAssertTrue(gate(house))
        XCTAssertTrue(gate(techno), "either selected genre satisfies the facet")
        XCTAssertFalse(gate(jazz))
    }

    func testDecadeGate() {
        let cfg = config(decades: [1990])
        let nineties = track("x", artist: "A", matchKey: "mk-x")
        let noughties = track("y", artist: "B", matchKey: "mk-y")
        let years = ["mk-x": 1995, "mk-y": 2005]
        guard let gate = RoonClient.customGate(cfg: cfg, genres: [:], years: years, calibration: nil) else {
            return XCTFail("expected a decade gate")
        }
        XCTAssertTrue(gate(nineties))
        XCTAssertFalse(gate(noughties))
    }

    func testSeedOnlyFacetsHaveNoGate() {
        // Artists/tracks define the sound by proximity, so no measured gate.
        let cfg = config(artists: ["Boards of Canada"], trackKeys: ["mk-1"])
        XCTAssertNil(RoonClient.customGate(cfg: cfg, genres: [:], years: [:], calibration: nil))
    }

    // MARK: Seed union

    func testResolveSeedsUnionsFacetsAndDropsDislikes() {
        let mine = track("mine", artist: "boards of canada")               // artist facet
        let house1 = track("house1", artist: "Other")                      // genre facet
        let house2 = track("house2", artist: "Other2")                     // genre facet
        let unrelated = track("jazz", artist: "Nobody")                    // neither
        let disliked = track("mine2", artist: "boards of canada", matchKey: "mk-disliked")
        let lib = [mine, house1, house2, unrelated, disliked]
        let genres = ["house1": Set(["house"]), "house2": Set(["house"])]
        let cfg = config(genres: ["house"], artists: ["Boards of Canada"])

        let seeds = RoonClient.resolveCustomSeeds(
            cfg: cfg, lib: lib, genres: genres, years: [:], calibration: nil,
            disliked: ["mk-disliked"], daySeed: "2026-07-06|custom:test")

        XCTAssertTrue(seeds.contains("mine"), "artist facet seeds the centroid")
        XCTAssertTrue(seeds.contains("house1") && seeds.contains("house2"), "genre facet seeds the centroid")
        XCTAssertFalse(seeds.contains("jazz"), "a track matching no facet isn't a seed")
        XCTAssertFalse(seeds.contains("mk-disliked"), "disliked tracks are excluded")
        XCTAssertEqual(seeds.count, Set(seeds).count, "no duplicate seed ids")
    }

    func testResolveSeedsEmptyForNoFacets() {
        let lib = [track("a", artist: "A")]
        let seeds = RoonClient.resolveCustomSeeds(
            cfg: config(), lib: lib, genres: [:], years: [:], calibration: nil,
            disliked: [], daySeed: "d")
        XCTAssertTrue(seeds.isEmpty)
    }

    // MARK: Relaxation (narrow combo still fills)

    func testGatedWithRelaxationTopsUpNarrowCombo() {
        // Only one track satisfies the combined gate, but minKeep is 3 → the two
        // best non-matching candidates top it up (the endless station never dries).
        let ranked = ["match", "n1", "n2", "n3"]
        let gate: (String) -> Bool = { $0 == "match" }
        let kept = RoonClient.gatedWithRelaxation(ranked, gate: gate, minKeep: 3)
        XCTAssertEqual(kept.first, "match", "matching tracks lead")
        XCTAssertEqual(kept.count, 3, "topped up to minKeep")
    }

    // MARK: Config JSON round-trip

    func testRadioConfigJSONRoundTrip() throws {
        let cfg = RadioConfig(
            id: "abc", name: "Zomeravond", enabled: false, syncToQobuz: true,
            artists: ["A", "B"], trackKeys: ["mk1"], genres: ["house"], moods: ["happy"],
            activities: ["workout"], decades: [1980, 1990], adventurousness: 0.6,
            targetCount: 30, qobuzPlaylistID: "42", updatedAt: "2026-07-06T00:00:00Z")
        let data = try JSONEncoder().encode(cfg)
        // Wire keys are snake_case (shared with the DB column names).
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"sync_to_qobuz\""))
        XCTAssertTrue(json.contains("\"track_keys\""))
        XCTAssertTrue(json.contains("\"target_count\""))
        let back = try JSONDecoder().decode(RadioConfig.self, from: data)
        XCTAssertEqual(back, cfg)
        XCTAssertEqual(back.radioID, "custom:abc")
        XCTAssertTrue(back.hasFacets)
    }

    // MARK: DB round-trip (migration v36 + CRUD)

    func testDatabaseCRUDRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try DatabaseManager(url: dir.appendingPathComponent("library.db"))

        let cfg = RadioConfig(id: "r1", name: "Focus-house",
                              artists: ["Boards of Canada"], genres: ["house"],
                              moods: ["happy"], decades: [1990, 2000], targetCount: 30)
        try await db.upsertRadioConfig(cfg)

        var all = try await db.listRadioConfigs()
        XCTAssertEqual(all.count, 1)
        // Array facets survive the JSON-column round-trip.
        XCTAssertEqual(all.first?.genres, ["house"])
        XCTAssertEqual(all.first?.decades.sorted(), [1990, 2000])
        XCTAssertEqual(all.first?.targetCount, 30)
        XCTAssertFalse(all.first?.updatedAt.isEmpty ?? true, "updated_at is stamped on save")

        // Upsert on the same id updates in place (no duplicate row).
        var edited = cfg
        edited.name = "Avond-house"
        edited.enabled = false
        try await db.upsertRadioConfig(edited)
        all = try await db.listRadioConfigs()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Avond-house")
        XCTAssertEqual(all.first?.enabled, false)

        // Qobuz id persists for rename-in-place, and clears again.
        try await db.setRadioConfigQobuzID(id: "r1", "999")
        let withQID = try await db.listRadioConfigs().first?.qobuzPlaylistID
        XCTAssertEqual(withQID, "999")
        try await db.setRadioConfigQobuzID(id: "r1", nil)
        let clearedQID = try await db.listRadioConfigs().first?.qobuzPlaylistID
        XCTAssertNil(clearedQID)

        try await db.deleteRadioConfig(id: "r1")
        let afterDelete = try await db.listRadioConfigs()
        XCTAssertTrue(afterDelete.isEmpty)
    }

    // MARK: Fork an AI radio → editable config ("overnemen")

    private func aiItem(_ id: String, label: String) -> AIRadioItem {
        AIRadioItem(id: id, category: RoonClient.RadioCategory(radioID: id)?.rawValue ?? "",
                    label: label, title: label, trackCount: 20, imageKey: nil,
                    selected: true, hidden: false)
    }

    // MARK: AI-radio hide/sync wire contract (server-of-record over HTTP)

    func testAIRadioSelectionRequestCarriesHiddenAndSelected() throws {
        // The management routes hinge on these fields surviving JSON both ways.
        for req in [AIRadioSelectionRequest(id: "artist:x", hidden: true),
                    AIRadioSelectionRequest(id: "genre:house", selected: false),
                    AIRadioSelectionRequest(syncEnabled: true)] {
            let data = try JSONEncoder().encode(req)
            let back = try JSONDecoder().decode(AIRadioSelectionRequest.self, from: data)
            XCTAssertEqual(back.id, req.id)
            XCTAssertEqual(back.hidden, req.hidden)
            XCTAssertEqual(back.selected, req.selected)
            XCTAssertEqual(back.syncEnabled, req.syncEnabled)
        }
    }

    func testAIRadioItemRoundTripsHidden() throws {
        let item = aiItem("artist:boards", label: "Boards of Canada")
        let mgmt = AIRadioManagement(syncEnabled: true, qobuzConfigured: true, radios: [item])
        let back = try JSONDecoder().decode(AIRadioManagement.self,
                                            from: try JSONEncoder().encode(mgmt))
        XCTAssertEqual(back.radios.first?.id, item.id)
        XCTAssertEqual(back.radios.first?.hidden, item.hidden)
        XCTAssertEqual(back.radios.first?.selected, item.selected)
    }

    func testForkMapsEachCategoryToItsFacet() {
        let artist = RoonClient.radioConfigFromAIRadio(aiItem("artist:boards", label: "Boards of Canada"))
        XCTAssertEqual(artist.artists, ["Boards of Canada"])
        XCTAssertTrue(artist.genres.isEmpty && artist.moods.isEmpty)

        let genre = RoonClient.radioConfigFromAIRadio(aiItem("genre:house", label: "House"))
        XCTAssertEqual(genre.genres, ["house"])

        let mood = RoonClient.radioConfigFromAIRadio(aiItem("mood:happy", label: "Vrolijk"))
        XCTAssertEqual(mood.moods, ["happy"])

        let activity = RoonClient.radioConfigFromAIRadio(aiItem("activity:workout", label: "Workout"))
        XCTAssertEqual(activity.activities, ["workout"])

        let decade = RoonClient.radioConfigFromAIRadio(aiItem("decade:1990", label: "Jaren 90"))
        XCTAssertEqual(decade.decades, [1990])

        // Each fork is a fresh, named, editable config with a new id.
        XCTAssertEqual(genre.name, "House")
        XCTAssertTrue(genre.enabled && genre.hasFacets)
        XCTAssertNotEqual(genre.id, mood.id)
    }

    func testForkSonicHasNoFacet() {
        let sonic = RoonClient.radioConfigFromAIRadio(aiItem("sonic:cluster-3", label: "Buurt 3"))
        XCTAssertFalse(sonic.hasFacets, "cluster radios have no facet to fork from")
        XCTAssertEqual(sonic.name, "Buurt 3")
    }

    // MARK: AI title fallback

    func testCustomRadiosShareTheAIQobuzNamespace() {
        // The crux of "really the same": a custom radio's Qobuz name uses the SAME
        // "RoonSage · " prefix as the AI radios (not a separate namespace), so one
        // shared reconcile keep-set governs both.
        var named = config(genres: ["house"]); named.name = "Zomeravond"
        let fallbackTitle = RoonClient.customFallbackMeta(cfg: named).title
        XCTAssertEqual(RoonClient.qobuzPlaylistName(for: fallbackTitle), "RoonSage · Zomeravond")
        // Same builder the AI radios use → identical prefix.
        XCTAssertTrue(RoonClient.qobuzPlaylistName(for: "X").hasPrefix(RoonClient.qobuzNamePrefix))
    }

    func testCustomFallbackMetaUsesNameAndFacets() {
        let cfg = config(genres: ["house"], moods: ["happy"], artists: ["Kiasmos"])
        var named = cfg; named.name = "Zomeravond"
        let meta = RoonClient.customFallbackMeta(cfg: named)
        XCTAssertEqual(meta.title, "Zomeravond")
        XCTAssertTrue(meta.description.contains("Kiasmos") || meta.description.contains("House"),
                      "fallback description summarises the facets")
    }
}
