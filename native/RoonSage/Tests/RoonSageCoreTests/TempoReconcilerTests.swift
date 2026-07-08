import AudioAnalysis
import XCTest

final class TempoReconcilerTests: XCTestCase {

    func testCorrectsHalfTimeWhenConfidenceLow() {
        // Detector locked onto half-time 64; Deezer says 128.
        let r = TempoReconciler.reconcile(nativeBPM: 64, confidence: 0.2, reference: 128)
        XCTAssertEqual(r, 128, accuracy: 0.001)
    }

    func testCorrectsDoubleTimeWhenConfidenceLow() {
        let r = TempoReconciler.reconcile(nativeBPM: 240, confidence: 0.3, reference: 120)
        XCTAssertEqual(r, 120, accuracy: 0.001)
    }

    func testKeepsNativeWhenConfident() {
        // High confidence → never touched, even with a disagreeing reference.
        let r = TempoReconciler.reconcile(nativeBPM: 64, confidence: 0.9, reference: 128)
        XCTAssertEqual(r, 64, accuracy: 0.001)
    }

    func testKeepsNativeWhenNoReference() {
        XCTAssertEqual(TempoReconciler.reconcile(nativeBPM: 64, confidence: 0.1, reference: nil), 64, accuracy: 0.001)
        XCTAssertEqual(TempoReconciler.reconcile(nativeBPM: 64, confidence: 0.1, reference: 0), 64, accuracy: 0.001)
    }

    func testRejectsMismatchedReference() {
        // Reference is a totally different tempo (wrong track): no octave of 100
        // (50/100/200) lands within ±6 % of 137 → keep native.
        let r = TempoReconciler.reconcile(nativeBPM: 100, confidence: 0.1, reference: 137)
        XCTAssertEqual(r, 100, accuracy: 0.001)
    }

    func testKeepsNativeWhenAlreadyNearestOctave() {
        // Native already agrees with the reference → unchanged.
        let r = TempoReconciler.reconcile(nativeBPM: 128, confidence: 0.2, reference: 127)
        XCTAssertEqual(r, 128, accuracy: 0.001)
    }
}
