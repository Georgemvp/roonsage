import RoonSageCore
import SwiftUI

/// Create-hub — de drie AI-curatie-tools starten identiek (`analyzeForFilters` →
/// kandidatenpool) en verschillen enkel in diepte en korrel:
///   - Genereer — GenerateView (volledige playlist: curatie + flow-ordening + titel)
///   - Snel     — AskView (instant library-antwoord, stopt na sonische rerank)
///   - Albums   — RecommendView (aanbevelingen op albumniveau i.p.v. tracks)
///
/// Voorheen drie losse sidebar-items; hier samengevoegd tot één modus-schakelaar
/// met Generate als vertrekpunt. De onderliggende views blijven ongewijzigd.
@MainActor
public struct CreateHubView: View {
    public init() {}

    enum Mode: String, CaseIterable, Identifiable {
        case generate, ask, albums
        var id: String { rawValue }
        var label: String {
            switch self {
            case .generate: "Genereer"
            case .ask:      "Snel"
            case .albums:   "Albums"
            }
        }
    }

    @State private var mode: Mode = .generate
    /// Query carried over when the user taps "Verfijn tot playlist →" in Snel (Ask).
    @State private var handoffPrompt: String?

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Modus", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch mode {
            case .generate: GenerateView(initialPrompt: handoffPrompt)
            case .ask:      AskView(onRefine: { prompt in
                handoffPrompt = prompt
                mode = .generate
            })
            case .albums:   RecommendView()
            }
        }
    }
}
