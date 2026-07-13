import XCTest
@testable import RoonSageCore

/// The dial→LB-Radio-mode mapping is the one piece of extractable pure logic in
/// the ListenBrainz producers (the rest is network glue). Guards the boundaries
/// so a silent off-by-one in the veilig/avontuurlijk split can't slip through.
final class ListenBrainzProducerTests: XCTestCase {
    func testRadioModeMapsDialToBands() {
        // Veilig end → easy (closest, most popular similar artists).
        XCTAssertEqual(ListenBrainzRadioProducer.radioMode(0.0), .easy)
        XCTAssertEqual(ListenBrainzRadioProducer.radioMode(0.33), .easy)
        // Middle band → medium.
        XCTAssertEqual(ListenBrainzRadioProducer.radioMode(0.34), .medium)
        XCTAssertEqual(ListenBrainzRadioProducer.radioMode(0.5), .medium)
        XCTAssertEqual(ListenBrainzRadioProducer.radioMode(0.66), .medium)
        // Avontuurlijk end → hard (deeper into the similarity graph).
        XCTAssertEqual(ListenBrainzRadioProducer.radioMode(0.67), .hard)
        XCTAssertEqual(ListenBrainzRadioProducer.radioMode(1.0), .hard)
        // The untouched-install default (0.35) lands on medium, matching the old
        // hardcoded behaviour so a fresh install's first run scores as before.
        XCTAssertEqual(ListenBrainzRadioProducer.radioMode(0.35), .medium)
    }
}
