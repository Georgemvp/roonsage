import Foundation
@testable import RoonSageCore
import XCTest

/// Gap G (AudioMuse-audit): bibliotheek-gekalibreerde mood-toewijzing.
final class MoodCalibrationTests: XCTestCase {

    private func t(_ id: String, moods: [String: Float]) -> DatabaseManager.SonicTrack {
        DatabaseManager.SonicTrack(id: id, title: id, artist: nil, album: nil, imageKey: nil,
                                   matchKey: id, bpm: 120, camelot: "8A", rmsEnergy: 0.5,
                                   tags: [], moods: moods)
    }

    /// "danceable" heeft bibliotheekbreed een hoge basislijn; een track die er
    /// nét onder zit maar op "sad" ver bóven de basislijn uitsteekt, hoort bij
    /// sad — rauwe argmax zou danceable zeggen.
    func testCalibrationBeatsRawArgmaxOnBiasedBaseline() {
        var lib: [DatabaseManager.SonicTrack] = []
        // Basislijn: danceable hoog (~0.60±0.02), sad laag (~0.15±0.02).
        for i in 0..<20 {
            lib.append(t("bg\(i)", moods: ["danceable": 0.60 + Float(i % 5) * 0.01,
                                           "sad": 0.15 + Float(i % 5) * 0.01]))
        }
        // De interessante track: danceable 0.58 (onder gemiddeld), sad 0.40 (ver erboven).
        let probe: [String: Float] = ["danceable": 0.58, "sad": 0.40]
        lib.append(t("probe", moods: probe))

        let cal = MoodCalibration(tracks: lib)
        XCTAssertEqual(cal.dominantMood(probe), "sad",
                       "z-score moet de tekst-prior-bias wegkalibreren")
        // Ter contrast: rauwe argmax kiest danceable.
        XCTAssertEqual(probe.max(by: { $0.value < $1.value })?.key, "danceable")
    }

    /// Vlak profiel (nergens bovengemiddeld) → geen mood-station.
    func testFlatProfileGetsNoMood() {
        var lib: [DatabaseManager.SonicTrack] = []
        for i in 0..<20 {
            lib.append(t("bg\(i)", moods: ["happy": 0.40 + Float(i % 5) * 0.01,
                                           "relaxed": 0.40 + Float(i % 5) * 0.01]))
        }
        let cal = MoodCalibration(tracks: lib)
        XCTAssertNil(cal.dominantMood(["happy": 0.40, "relaxed": 0.40]),
                     "gemiddeld-overal = geen dominante mood")
    }

    /// Te weinig waarnemingen (< 8) → geen statistiek → rauwe argmax-fallback.
    func testSmallLibraryFallsBackToRawArgmax() {
        let lib = (0..<3).map { t("s\($0)", moods: ["party": 0.5]) }
        let cal = MoodCalibration(tracks: lib)
        XCTAssertEqual(cal.dominantMood(["party": 0.6, "sad": 0.2]), "party")
        XCTAssertNil(cal.dominantMood(["party": 0.1]), "onder de rauwe 0.3-floor")
    }
}
