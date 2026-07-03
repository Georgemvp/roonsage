import XCTest
@testable import RoonSageCore

final class LocalLoudnessTests: XCTestCase {
    func testOffModeIsUnityGain() {
        XCTAssertEqual(LocalLoudness.gainDB(trackLufs: -6, albumLufs: -8, mode: .off, preampDB: 5), 0)
        XCTAssertEqual(LocalLoudness.volume(trackLufs: -6, albumLufs: nil, mode: .off, preampDB: 0), 1)
    }

    func testLoudMasterIsAttenuated() {
        // −9 LUFS master, −14 target → −5 dB → ×10^(−5/20) ≈ 0.562
        let v = LocalLoudness.volume(trackLufs: -9, albumLufs: nil, mode: .track, preampDB: 0)
        XCTAssertEqual(v, Float(pow(10.0, -5.0 / 20)), accuracy: 0.001)
    }

    func testQuietTrackClampsAtUnityNoBoost() {
        // −20 LUFS → +6 dB wanted, but AVPlayer.volume can't exceed 1.
        XCTAssertEqual(LocalLoudness.volume(trackLufs: -20, albumLufs: nil, mode: .track, preampDB: 0), 1)
    }

    func testAlbumModePrefersAlbumMean() {
        let db = LocalLoudness.gainDB(trackLufs: -6, albumLufs: -10, mode: .album, preampDB: 0)
        XCTAssertEqual(db, -4, accuracy: 0.0001) // −14 − (−10)
    }

    func testAlbumModeFallsBackToTrackThenAssumed() {
        XCTAssertEqual(LocalLoudness.gainDB(trackLufs: -8, albumLufs: nil, mode: .album, preampDB: 0),
                       -6, accuracy: 0.0001)
        XCTAssertEqual(LocalLoudness.gainDB(trackLufs: nil, albumLufs: nil, mode: .album, preampDB: 0),
                       LocalLoudness.targetLufs - LocalLoudness.assumedLufsWhenUnknown, accuracy: 0.0001)
    }

    func testUnknownTrackAssumesLoudMaster() {
        // Unmeasured tracks must not blast between normalized neighbours:
        // assumed −9 → −5 dB attenuation, same as a real loud master.
        let v = LocalLoudness.volume(trackLufs: nil, albumLufs: nil, mode: .track, preampDB: 0)
        XCTAssertLessThan(v, 1)
    }

    func testPreampShiftsGain() {
        let base = LocalLoudness.gainDB(trackLufs: -9, albumLufs: nil, mode: .track, preampDB: 0)
        let boosted = LocalLoudness.gainDB(trackLufs: -9, albumLufs: nil, mode: .track, preampDB: 3)
        XCTAssertEqual(boosted - base, 3, accuracy: 0.0001)
    }

    func testExtremeAttenuationStaysInRange() {
        let v = LocalLoudness.volume(trackLufs: 40, albumLufs: nil, mode: .track, preampDB: -12)
        XCTAssertGreaterThanOrEqual(v, 0)
        XCTAssertLessThan(v, 0.001) // −66 dB
    }
}
