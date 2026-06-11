import AnalyzerCore
import XCTest

final class AccuracyValidatorTests: XCTestCase {

    // MARK: BPM classification

    func testBPMExactWithinTolerance() {
        XCTAssertEqual(AccuracyValidator.classifyBPM(analyzed: 122.0, reference: 120.0), .exact)
        XCTAssertEqual(AccuracyValidator.classifyBPM(analyzed: 120.0, reference: 120.0), .exact)
    }

    func testBPMOctaveErrors() {
        XCTAssertEqual(AccuracyValidator.classifyBPM(analyzed: 60.0, reference: 120.0), .halfTempo)
        XCTAssertEqual(AccuracyValidator.classifyBPM(analyzed: 240.0, reference: 120.0), .doubleTempo)
    }

    func testBPMOff() {
        XCTAssertEqual(AccuracyValidator.classifyBPM(analyzed: 100.0, reference: 128.0), .off)
        XCTAssertEqual(AccuracyValidator.classifyBPM(analyzed: 0, reference: 120), .off)
    }

    // MARK: Key (Camelot) classification

    func testKeyExact() {
        XCTAssertEqual(AccuracyValidator.classifyKey(analyzed: "8A", reference: "8A"), .exact)
    }

    func testKeyRelativeMajorMinorSwap() {
        // 8A = A minor, 8B = C major — relative keys, the classic major/minor confusion.
        XCTAssertEqual(AccuracyValidator.classifyKey(analyzed: "8A", reference: "8B"), .relative)
    }

    func testKeyNeighbourOnWheel() {
        XCTAssertEqual(AccuracyValidator.classifyKey(analyzed: "9A", reference: "8A"), .neighbor)
        XCTAssertEqual(AccuracyValidator.classifyKey(analyzed: "7A", reference: "8A"), .neighbor)
        // Wheel wraps: 12 ↔ 1.
        XCTAssertEqual(AccuracyValidator.classifyKey(analyzed: "1A", reference: "12A"), .neighbor)
    }

    func testKeyOffAndUnparseable() {
        XCTAssertEqual(AccuracyValidator.classifyKey(analyzed: "3A", reference: "8A"), .off)
        XCTAssertEqual(AccuracyValidator.classifyKey(analyzed: "", reference: "8A"), .off)
        XCTAssertEqual(AccuracyValidator.classifyKey(analyzed: "13A", reference: "8A"), .off)
    }

    // MARK: CSV parsing

    func testParseReferenceCSVSkipsHeaderAndQuotes() {
        let csv = """
        artist,title,bpm,camelot
        Daft Punk,"Harder, Better, Faster, Stronger",123,9B
        Calvin Harris feat. Rihanna,This Is What You Came For,124,11B
        """
        let ref = AccuracyValidator.parseReferenceCSV(csv)
        XCTAssertEqual(ref.count, 2)
        // Quoted title with embedded commas parses as one field.
        XCTAssertNotNil(ref.values.first { $0.bpm == 123 && $0.camelot == "9B" })
    }

    func testParseReferenceCSVHandlesNoHeader() {
        let ref = AccuracyValidator.parseReferenceCSV("Adele,Hello,79,9B")
        XCTAssertEqual(ref.count, 1)
        XCTAssertEqual(ref.values.first?.bpm, 79)
    }
}
