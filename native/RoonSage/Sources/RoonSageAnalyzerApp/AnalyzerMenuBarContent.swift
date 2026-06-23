import AppKit
import RoonSageCore
import SwiftUI

/// Menubar status item for the always-on server: Roon / analyse / feature-server
/// at a glance, plus reconnect + pause/resume + open-window, so the server is
/// controllable when its window is closed.
@MainActor
struct AnalyzerMenuBarContent: View {
    @Environment(AnalyzerModel.self) private var model
    @Environment(RoonClient.self) private var client
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("RoonSage Analyzer").font(.subheadline.bold())
                    Text("v\(AnalyzerUpdater.currentVersion) · server").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)

            Divider()

            statusRow(dot: client.connectionState.isConnected ? .green : .orange,
                      title: "Roon", detail: client.connectionState.label)
            if !client.connectionState.isConnected {
                menuButton("Opnieuw verbinden") { reconnect() }
            }

            statusRow(dot: model.isAnalyzing ? .blue : .secondary,
                      title: "Analyse",
                      detail: model.isAnalyzing ? analyzeDetail
                                                : "\(model.trackCount) geanalyseerd · \(model.taggedCount) getagd")
            if !model.musicPath.isEmpty {
                if model.isAnalyzing {
                    menuButton("Pauzeer analyse") { model.cancelAnalyze() }
                } else {
                    menuButton(model.trackCount > 0 ? "Hervat analyse" : "Start analyse") { model.startAnalyze() }
                }
            }

            statusRow(dot: model.isServing ? .green : .secondary,
                      title: "Feature-server",
                      detail: model.isServing ? "Actief op poort \(model.port)" : "Gestopt")

            Divider()

            menuButton("Venster openen") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            menuButton("Analyzer afsluiten") { NSApplication.shared.terminate(nil) }
                .padding(.bottom, 6)
        }
        .frame(width: 280)
    }

    private var analyzeDetail: String {
        guard let p = model.analyze, p.total > 0 else { return "Bezig…" }
        return "\(p.done + p.failed) / \(p.total) · \(p.failed) mislukt"
    }

    private func reconnect() {
        Task {
            await client.disconnect()
            if let host = client.savedHost { await client.connect(host: host, port: client.savedPort) }
            else { await client.discoverAndConnect() }
        }
    }

    @ViewBuilder
    private func statusRow(dot: Color, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(title).font(.callout.weight(.medium))
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    @ViewBuilder
    private func menuButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}
