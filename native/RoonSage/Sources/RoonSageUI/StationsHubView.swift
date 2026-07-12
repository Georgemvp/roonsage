import RoonSageCore
import SwiftUI

/// Stations-hub — de drie eindeloze/zelf-sturende stations delen allemaal
/// `RadioEngine`: een DJ-persona is een radio met de avontuurlijkheids-dial + arc
/// voorgekookt, en Sonic Journeys zijn radio-vormige station-types. Voorheen drie
/// losse sidebar-items; hier samengevoegd tot één modus-schakelaar.
///   - Radio's  — SonicRadioView (dagelijkse for-you stations + dial)
///   - DJ-modi  — DJModesView (persona-presets over RadioEngine)
///   - Journeys — SonicJourneysView (Album Radio / Time Machine / The Bridge)
///
/// De onderliggende views blijven ongewijzigd.
@MainActor
public struct StationsHubView: View {
    public init() {}

    enum Mode: String, CaseIterable, Identifiable {
        case radios, djModes, journeys
        var id: String { rawValue }
        var label: String {
            switch self {
            case .radios:   "Radio's"
            case .djModes:  "DJ-modi"
            case .journeys: "Journeys"
            }
        }
    }

    @State private var mode: Mode = .radios

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Modus", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch mode {
            case .radios:   SonicRadioView()
            case .djModes:  DJModesView()
            case .journeys: SonicJourneysView()
            }
        }
    }
}
