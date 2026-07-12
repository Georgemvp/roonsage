import RoonSageCore
import SwiftUI

/// Taste-hub — bundelt de vier "jouw smaak"-surfaces op één plek. Ze putten uit
/// twee bronnen: audio-DNA (CLAP-embeddings) en luistergeschiedenis
/// (`listening_history`). Voorheen vier losse sidebar-items; hier samengevoegd
/// tot één modus-schakelaar zodat "ken mijn smaak" op één plek zit.
///   - DNA      — SonicFingerprintView (embeddings + TasteVector)
///   - Smaak    — TasteProfileView (genres/artiesten/Last.fm)
///   - Historie — RecentView (recent gespeeld, on-this-day, time machine)
///   - Jaar     — YearInReviewView (Sonic Wrapped per jaar)
///
/// De onderliggende views blijven ongewijzigd.
@MainActor
public struct TasteHubView: View {
    public init() {}

    enum Mode: String, CaseIterable, Identifiable {
        case dna, profile, history, year
        var id: String { rawValue }
        var label: String {
            switch self {
            case .dna:     "DNA"
            case .profile: "Smaak"
            case .history: "Historie"
            case .year:    "Jaar"
            }
        }
    }

    @State private var mode: Mode = .dna

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Modus", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch mode {
            case .dna:     SonicFingerprintView()
            case .profile: TasteProfileView()
            case .history: RecentView()
            case .year:    YearInReviewView()
            }
        }
    }
}
