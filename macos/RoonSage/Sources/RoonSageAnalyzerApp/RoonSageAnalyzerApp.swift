import SwiftUI

@MainActor
@main
struct RoonSageAnalyzerApp: App {
    @State private var model = AnalyzerModel()
    @State private var updater = AnalyzerUpdater()

    var body: some Scene {
        Window("RoonSage Analyzer", id: "main") {
            AnalyzerView()
                .environment(model)
                .environment(updater)
                .frame(minWidth: 540, minHeight: 600)
                .task { await updater.checkOnLaunch() }
        }
        .windowResizability(.contentSize)
    }
}
