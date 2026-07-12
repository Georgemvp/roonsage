import RoonSageCore
import SwiftUI

/// DJ — harmonisch mixen op rauwe analyzer-features (bpm/Camelot), géén RadioEngine.
/// Twee vormen van dezelfde mixer, voorheen twee losse sidebar-items:
///   - Set  — DJSetView (batch: hele set uit BPM-curve + tags)
///   - Live — LiveDJView (incrementeel: wat mixt in de now-playing track)
///
/// De onderliggende views blijven ongewijzigd.
@MainActor
public struct DJView: View {
    public init() {}

    enum Mode: String, CaseIterable, Identifiable {
        case set, live
        var id: String { rawValue }
        var label: String { self == .set ? "Set" : "Live" }
    }

    @State private var mode: Mode = .set

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Modus", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch mode {
            case .set:  DJSetView()
            case .live: LiveDJView()
            }
        }
    }
}
