import XCTest
@testable import RoonSageCore

final class TitleGroundingTests: XCTestCase {

    private func st(_ id: String, energy: Double? = nil, attrs: [String: Float] = [:],
                    moods: [String: Float] = [:], tags: [String] = [], bpm: Double? = nil) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(id: id, title: "T\(id)", artist: "A", album: nil, imageKey: nil,
                                   matchKey: "mk\(id)", bpm: bpm, camelot: "8A", energy: energy,
                                   tags: tags, embedding: nil, moods: moods, attributes: attrs)
    }

    // MARK: violationWords (the corrective-retry ban list)

    /// The live failure: the LABEL reads "melancholisch (gemeten: eerder vrolijk)",
    /// so a prompt saying "zonder deze woorden" also banned *vrolijk* — the word
    /// the measurements actually support. The ban list must name only the
    /// forbidden spellings.
    func testViolationWordsExcludeTheSupportedOpposite() {
        let stats = TitleGrounding.SelectionStats(attributeAvg: ["valence": 0.75], energyAvg: nil)
        let words = TitleGrounding.violationWords(
            title: "Melancholische ballades", description: "Weemoedige liedjes.", stats: stats)
        XCTAssertTrue(words.contains("melancholisch"), "the violated claim's words are banned")
        XCTAssertTrue(words.contains("weemoedig"))
        XCTAssertFalse(words.contains("vrolijk"), "must not ban the word the measurements support")
        XCTAssertFalse(words.contains("zonnig"))
    }

    func testViolationWordsEmptyWhenGrounded() {
        let stats = TitleGrounding.SelectionStats(attributeAvg: ["acousticness": 0.8], energyAvg: nil)
        XCTAssertTrue(TitleGrounding.violationWords(
            title: "Akoestische parels", description: "Mooi.", stats: stats).isEmpty)
    }

    func testViolationWordsSkipFragmentMatchers() {
        let stats = TitleGrounding.SelectionStats(attributeAvg: ["danceability": 0.1], energyAvg: nil)
        let words = TitleGrounding.violationWords(
            title: "Dansbare hits", description: "", stats: stats)
        XCTAssertTrue(words.contains("dansbaar"))
        XCTAssertFalse(words.contains(where: { $0.hasSuffix("-") }), "no fragment matchers in a human ban list")
        XCTAssertEqual(words, words.sorted(), "deterministic order")
    }

    // MARK: Claim validation

    func testAcousticClaimOnElectronicSelectionIsViolation() {
        let stats = TitleGrounding.SelectionStats(attributeAvg: ["acousticness": 0.2], energyAvg: nil)
        let v = TitleGrounding.violations(title: "Dromerige akoestische avond", stats: stats)
        XCTAssertFalse(v.isEmpty, "akoestisch on measured-electronic must violate")
    }

    func testAcousticClaimOnAcousticSelectionPasses() {
        let stats = TitleGrounding.SelectionStats(attributeAvg: ["acousticness": 0.7], energyAvg: nil)
        XCTAssertTrue(TitleGrounding.violations(title: "Akoestische parels", stats: stats).isEmpty)
    }

    func testClaimWithoutMeasurementIsNotViolation() {
        // No acousticness data at all → benefit of the doubt, not a violation.
        let stats = TitleGrounding.SelectionStats(attributeAvg: [:], energyAvg: nil)
        XCTAssertTrue(TitleGrounding.violations(title: "Akoestische avond", stats: stats).isEmpty)
    }

    func testEnergyClaims() {
        let hot = TitleGrounding.SelectionStats(attributeAvg: [:], energyAvg: 0.85)
        XCTAssertFalse(TitleGrounding.violations(title: "Rustige zondagochtend", stats: hot).isEmpty)
        XCTAssertTrue(TitleGrounding.violations(title: "Energieke house", stats: hot).isEmpty)

        let cold = TitleGrounding.SelectionStats(attributeAvg: [:], energyAvg: 0.2)
        XCTAssertFalse(TitleGrounding.violations(title: "Energieke house", stats: cold).isEmpty)
        XCTAssertTrue(TitleGrounding.violations(title: "Rustige zondagochtend", stats: cold).isEmpty)
    }

    /// The grey zone that shipped "akoestisch" playlists: 0.45–0.55 was too weak
    /// to ASSERT the descriptor but too weak to REJECT it either, so the LLM had
    /// free rein over the middle of the library. A claim must now clear the same
    /// bar that would have asserted it.
    func testAcousticClaimInGreyZoneIsViolation() {
        for avg: Float in [0.46, 0.50, 0.54] {
            let stats = TitleGrounding.SelectionStats(attributeAvg: ["acousticness": avg], energyAvg: nil)
            XCTAssertFalse(TitleGrounding.violations(title: "Akoestische parels", stats: stats).isEmpty,
                           "acousticness \(avg) is neutral — must not sustain an akoestisch claim")
            XCTAssertNil(TitleGrounding.band(axis: "acousticness", selectionAvg: avg, calibration: nil),
                         "band and violations must agree that \(avg) is neutral")
        }
    }

    /// The claim the user actually hit: the bogus "akoestisch" lived in the
    /// DESCRIPTION, which used to reach Qobuz completely unvalidated.
    func testDescriptionClaimsAreValidatedToo() {
        let stats = TitleGrounding.SelectionStats(attributeAvg: ["acousticness": 0.2], energyAvg: nil)
        XCTAssertTrue(TitleGrounding.violations(title: "Warme jaren 90 party", stats: stats).isEmpty,
                      "title alone makes no claim")
        let both = TitleGrounding.violations(title: "Warme jaren 90 party",
                                             description: "Dansbare, akoestische poprockklassieken.",
                                             stats: stats)
        XCTAssertFalse(both.isEmpty, "an ungrounded claim in the description must be caught")
    }

    func testTitleAndDescriptionClaimReportedOnce() {
        let stats = TitleGrounding.SelectionStats(attributeAvg: ["acousticness": 0.2], energyAvg: nil)
        let v = TitleGrounding.violations(title: "Akoestische avond",
                                          description: "Puur akoestisch genieten.", stats: stats)
        XCTAssertEqual(v.count, 1, "the same claim in both fields is one thing to fix")
    }

    func testNeutralTitleNeverViolates() {
        let stats = TitleGrounding.SelectionStats(attributeAvg: ["acousticness": 0.1, "valence": 0.1],
                                                  energyAvg: 0.9)
        XCTAssertTrue(TitleGrounding.violations(title: "Melodieuze indie-rock", stats: stats).isEmpty)
    }

    // MARK: Calibration

    func testPercentileAgainstLibrary() {
        let lib = (0..<10).map { st("\($0)", attrs: ["acousticness": Float($0) / 10]) }
        let cal = TitleGrounding.Calibration.compute(library: lib)
        XCTAssertEqual(cal.percentile(of: 0.95, axis: "acousticness"), 1.0)
        XCTAssertEqual(cal.percentile(of: 0.0, axis: "acousticness"), 0.0)
        XCTAssertNil(cal.percentile(of: 0.5, axis: "valence"), "axis without data → nil")
        let mid = cal.percentile(of: 0.5, axis: "acousticness") ?? 0
        XCTAssertEqual(mid, 0.5, accuracy: 0.11)
    }

    func testBandRequiresBothAbsoluteAndRelativeLean() {
        // Library that is uniformly acoustic-scored high: a 0.56 selection is
        // absolutely "high" but sits at the BOTTOM of the library → no claim.
        let lib = (0..<10).map { st("\($0)", attrs: ["acousticness": 0.6 + Float($0) * 0.04]) }
        let cal = TitleGrounding.Calibration.compute(library: lib)
        XCTAssertNil(TitleGrounding.band(axis: "acousticness", selectionAvg: 0.56, calibration: cal))
        // A selection above most of the library DOES claim.
        XCTAssertEqual(TitleGrounding.band(axis: "acousticness", selectionAvg: 0.95, calibration: cal),
                       "akoestisch")
    }

    func testBandWithoutCalibrationFallsBackToAbsolute() {
        XCTAssertEqual(TitleGrounding.band(axis: "acousticness", selectionAvg: 0.7, calibration: nil),
                       "akoestisch")
        XCTAssertEqual(TitleGrounding.band(axis: "acousticness", selectionAvg: 0.3, calibration: nil),
                       "elektronisch")
        XCTAssertNil(TitleGrounding.band(axis: "acousticness", selectionAvg: 0.5, calibration: nil))
    }

    // MARK: Profile signature

    func testSignatureStableAcrossRotationWithinBands() {
        let a = (0..<20).map { st("\($0)", energy: 0.55, attrs: ["valence": 0.6],
                                  moods: ["happy": 0.5], tags: ["melodic"], bpm: 120) }
        // A different daily selection from the same sonic pool: same bands.
        let b = (0..<20).map { st("x\($0)", energy: 0.58, attrs: ["valence": 0.58],
                                  moods: ["happy": 0.6], tags: ["melodic"], bpm: 124) }
        XCTAssertEqual(TitleGrounding.profileSignature(a), TitleGrounding.profileSignature(b))
    }

    func testSignatureShiftsWhenCharacterDrifts() {
        let calm = (0..<20).map { st("\($0)", energy: 0.2, moods: ["relaxed": 0.6], bpm: 80) }
        let hard = (0..<20).map { st("h\($0)", energy: 0.9, moods: ["aggressive": 0.6], bpm: 160) }
        XCTAssertNotEqual(TitleGrounding.profileSignature(calm), TitleGrounding.profileSignature(hard))
    }

    func testEmptySelectionYieldsEmptySignature() {
        XCTAssertEqual(TitleGrounding.profileSignature([]), "")
    }

    // MARK: Energy signal (arousal preferred, percentile-calibrated)

    func testEnergySignalPrefersArousalOverRMS() throws {
        let t = st("1", energy: 0.5, attrs: ["arousal": 0.9])
        XCTAssertEqual(try XCTUnwrap(TitleGrounding.energySignal(t)), 0.9, accuracy: 1e-6)
        let noArousal = st("2", energy: 0.3)
        XCTAssertEqual(try XCTUnwrap(TitleGrounding.energySignal(noArousal)), 0.3, accuracy: 1e-6)
    }

    func testEnergyClaimIsLibraryRelativeNotAbsolute() {
        // A library whose energy signal is compressed into [0, 0.35] (the real
        // RMS bug). A selection at 0.32 is the TOP of this library → "energiek"
        // must be allowed even though 0.32 is absolutely low.
        let lib = (0..<20).map { st("\($0)", attrs: ["arousal": Float($0) * 0.0175]) } // 0 … 0.33
        let cal = TitleGrounding.Calibration.compute(library: lib)
        let hot = TitleGrounding.SelectionStats(attributeAvg: [:], energyAvg: 0.32)
        XCTAssertTrue(TitleGrounding.violations(title: "Energieke sessie", stats: hot, calibration: cal).isEmpty,
                      "top-of-library energy must satisfy an 'energiek' claim")
        // And "rustig" on that same top-of-library selection IS a contradiction.
        XCTAssertFalse(TitleGrounding.violations(title: "Rustige avond", stats: hot, calibration: cal).isEmpty)
        // A bottom-of-library selection: mirror image.
        let cold = TitleGrounding.SelectionStats(attributeAvg: [:], energyAvg: 0.02)
        XCTAssertTrue(TitleGrounding.violations(title: "Rustige avond", stats: cold, calibration: cal).isEmpty)
        XCTAssertFalse(TitleGrounding.violations(title: "Energieke sessie", stats: cold, calibration: cal).isEmpty)
    }

    func testEnergyCalibrationFoldsInSignal() {
        let lib = (0..<10).map { st("\($0)", energy: Double($0) / 10) }
        let cal = TitleGrounding.Calibration.compute(library: lib)
        XCTAssertEqual(cal.percentile(of: 0.95, axis: TitleGrounding.energyAxis), 1.0)
        XCTAssertEqual(cal.energyPercentile(st("x", energy: 0.0)), 0.0)
    }
}

final class SonicClusterLabelTests: XCTestCase {

    private func st(_ id: String, tags: [String] = [], moods: [String: Float] = [:],
                    attrs: [String: Float] = [:]) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(id: id, title: "T\(id)", artist: "A", album: nil, imageKey: nil,
                                   matchKey: "mk\(id)", bpm: nil, camelot: "8A", energy: nil,
                                   tags: tags, embedding: nil, moods: moods, attributes: attrs)
    }

    func testDominantGenreStillWins() {
        let members = (0..<10).map { st("\($0)", tags: ["acoustic"]) }
        let genres = Dictionary(uniqueKeysWithValues: members.map { ($0.id, Set(["Jazz"])) })
        XCTAssertEqual(SonicClusters.label(for: members, genresById: genres, index: 0), "Jazz")
    }

    func testBareEnglishTagIsLocalized() {
        let members = (0..<10).map { st("\($0)", tags: ["acoustic"],
                                        attrs: ["acousticness": 0.8]) }
        let label = SonicClusters.label(for: members, genresById: [:], index: 0)
        XCTAssertTrue(label.hasPrefix("Akoestisch"), "got \(label)")
        XCTAssertFalse(label.contains("Acoustic"))
    }

    func testContradictedTagIsRejected() {
        // Every track tagged "acoustic" but MEASURED electronic → the tag may not
        // name the station; falls through to the mood.
        let members = (0..<10).map { st("\($0)", tags: ["acoustic"],
                                        moods: ["relaxed": 0.6],
                                        attrs: ["acousticness": 0.15]) }
        let label = SonicClusters.label(for: members, genresById: [:], index: 0)
        XCTAssertFalse(label.lowercased().contains("akoestisch"), "got \(label)")
        XCTAssertEqual(label, "Ontspannen")
    }

    func testUnknownTagNeverNamesStation() {
        let members = (0..<10).map { st("\($0)", tags: ["female vocalists"],
                                        moods: ["happy": 0.5]) }
        XCTAssertEqual(SonicClusters.label(for: members, genresById: [:], index: 0), "Vrolijk")
    }

    func testFallsBackToNeighborhoodNumber() {
        let members = (0..<10).map { st("\($0)") }
        XCTAssertEqual(SonicClusters.label(for: members, genresById: [:], index: 3), "Sonische buurt 4")
    }

    func testTagBelowCorroborationThresholdFallsThrough() {
        // 3/10 have the tag (30% < 40% bar) → mood names it instead.
        var members = (0..<3).map { st("\($0)", tags: ["ambient"], moods: ["relaxed": 0.5]) }
        members += (3..<10).map { st("\($0)", moods: ["relaxed": 0.5]) }
        XCTAssertEqual(SonicClusters.label(for: members, genresById: [:], index: 0), "Ontspannen")
    }
}
