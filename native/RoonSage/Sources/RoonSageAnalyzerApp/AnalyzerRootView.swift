import RoonSageCore
import RoonSageUI
import SwiftUI

/// The analyzer/server app shell: a macOS sidebar (NavigationSplitView) with four
/// sections. The Server section reuses the shared `SettingsView(role: .server)`;
/// the others are analyzer-app-specific screens.
@MainActor
struct AnalyzerRootView: View {
    @State private var section: Section? = .dashboard

    enum Section: String, CaseIterable, Identifiable {
        case dashboard, analyzer, radios, server
        var id: String { rawValue }

        var title: String {
            switch self {
            case .dashboard: return "Dashboard"
            case .analyzer:  return "Analyzer"
            case .radios:    return "Radio's"
            case .server:    return "Server"
            }
        }
        var icon: String {
            switch self {
            case .dashboard: return "square.grid.2x2"
            case .analyzer:  return "waveform.path.ecg"
            case .radios:    return "dot.radiowaves.left.and.right"
            case .server:    return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(Section.allCases) { s in
                    Label(s.title, systemImage: s.icon).tag(s)
                }
            }
            .navigationTitle("RoonSage")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            NavigationStack {
                detail
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section ?? .dashboard {
        case .dashboard: DashboardView()
        case .analyzer:  AnalyzerView()
        case .radios:    SonicRadioSettingsView()
        case .server:    SettingsView(role: .server)
        }
    }
}
