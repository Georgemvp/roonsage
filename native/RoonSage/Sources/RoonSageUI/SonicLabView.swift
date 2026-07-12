import RoonSageCore
import SwiftUI

/// Sonic Lab — één ingang voor de drie sonische vector-tools die allemaal op
/// dezelfde substraat draaien (`sonicLibrary()` + `sonicVectorIndex()` →
/// `[SonicEngine.Scored]`). Ze verschillen enkel in de vector-operatie:
///   - Zoek — tekst → CLAP-vector, cosine-kNN            (SonicSearchView)
///   - Mix  — mean(add) − 0.5·mean(subtract), cosine-kNN (SongAlchemyView)
///   - Brug — interpoleer tussen twee tracks             (SongPathsView)
///
/// Voorheen drie losse sidebar-items (Sonic search / Song Alchemy / The Bridge);
/// hier samengevoegd tot één modus-schakelaar zodat de "sonisch navigeren"-intentie
/// op één plek zit. De onderliggende views blijven ongewijzigd — The Bridge wordt
/// óók nog los aangeroepen vanuit Sonic Journeys.
@MainActor
public struct SonicLabView: View {
    public init() {}

    enum Mode: String, CaseIterable, Identifiable {
        case search, mix, bridge
        var id: String { rawValue }
        var label: String {
            switch self {
            case .search: "Zoek"
            case .mix:    "Mix"
            case .bridge: "Brug"
            }
        }
    }

    @State private var mode: Mode = .search

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Modus", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch mode {
            case .search: SonicSearchView()
            case .mix:    SongAlchemyView()
            case .bridge: SongPathsView()
            }
        }
    }
}
