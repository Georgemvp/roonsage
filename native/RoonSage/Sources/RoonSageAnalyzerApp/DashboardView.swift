import RoonSageCore
import RoonSageUI
import SwiftUI

/// At-a-glance status of the always-on server: Roon, analysis, the feature server,
/// Qobuz and the radio mirror — each a card with the live state.
@MainActor
struct DashboardView: View {
    @Environment(RoonClient.self) private var client
    @Environment(AnalyzerModel.self) private var model
    @Environment(AnalyzerUpdater.self) private var updater

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: Spacing.lg)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header
                if let u = updater.available { updateBanner(u) }
                LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.lg) {
                    roonCard
                    libraryCard
                    serverCard
                    qobuzCard
                    radioCard
                }
            }
            .padding(Spacing.xl)
        }
        .navigationTitle("Dashboard")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RoonSage Analyzer").font(.title2.bold())
            Text("v\(AnalyzerUpdater.currentVersion) · always-on server — analyse, tags & sonische radio's")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Cards

    private var roonCard: some View {
        StatusCard(title: "Roon", icon: "link", tint: client.connectionState.isConnected ? .green : .orange) {
            HStack(spacing: Spacing.sm) {
                if client.connectionState.isBusy { ProgressView().controlSize(.small) }
                Text(client.connectionState.label).font(.headline)
            }
            if let host = client.coreHost {
                Text("\(host):\(client.corePort)").font(.caption).foregroundStyle(.secondary)
            }
            if !client.connectionState.isConnected {
                Button("Opnieuw verbinden") { reconnectRoon() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
    }

    /// Force an immediate reconnect attempt — breaks a stuck `.connecting` state
    /// without restarting the app. The background connect loop then takes over.
    private func reconnectRoon() {
        Task {
            await client.disconnect()
            if let host = client.savedHost {
                await client.connect(host: host, port: client.savedPort)
            } else {
                await client.discoverAndConnect()
            }
        }
    }

    private var libraryCard: some View {
        StatusCard(title: "Analyse", icon: "waveform.path.ecg") {
            Text("\(model.trackCount) geanalyseerd").font(.headline)
            Text("\(model.taggedCount) getagd").font(.caption).foregroundStyle(.secondary)
            if model.isAnalyzing, let p = model.analyze, p.total > 0 {
                ProgressView(value: Double(p.done + p.failed) / Double(p.total))
            }
        }
    }

    private var serverCard: some View {
        StatusCard(title: "Feature-server", icon: "dot.radiowaves.left.and.right",
                   tint: model.isServing ? .green : .secondary) {
            Text(model.isServing ? "Actief" : "Gestopt").font(.headline)
            Text(model.isServing ? "Poort \(model.port)" : "Niet actief")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var qobuzCard: some View {
        StatusCard(title: "Qobuz", icon: "music.note.list",
                   tint: client.qobuzConfigured ? .green : .orange) {
            Text(client.qobuzConfigured ? "Verbonden" : "Niet ingesteld").font(.headline)
            Text(client.qobuzConfigured ? "Klaar voor playlist-sync" : "Stel in onder Server")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var radioCard: some View {
        StatusCard(title: "Sonische radio's", icon: "antenna.radiowaves.left.and.right",
                   tint: client.radioSyncEnabled ? .accentColor : .secondary) {
            Text(client.radioSyncEnabled ? "Sync aan" : "Sync uit").font(.headline)
            Text(radioSubtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var radioSubtitle: String {
        guard client.radioSyncEnabled else { return "Geen mirror naar Qobuz" }
        if let sel = client.radioSyncSelection {
            return "\(sel.count) radio('s) geselecteerd"
        }
        return "Automatisch (dagdeel-rotatie)"
    }

    @ViewBuilder
    private func updateBanner(_ info: AnalyzerUpdater.UpdateInfo) -> some View {
        HStack {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            Text("Update beschikbaar: v\(info.version)")
            Spacer()
            if updater.isInstalling {
                ProgressView().controlSize(.small)
            } else {
                Button("Update & herstart") { Task { await updater.installUpdate() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Spacing.md)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.lg))
    }
}

/// A simple titled status card used on the dashboard.
@MainActor
private struct StatusCard<Content: View>: View {
    let title: String
    let icon: String
    var tint: Color = .accentColor
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            content
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(Spacing.lg)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(Color.secondary.opacity(0.12))
        )
    }
}
