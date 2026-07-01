import RoonSageCore
import RoonSageUI
import SwiftUI

/// Server-authoritative tuning for "Ontdek Wekelijks" — the library-first weekly
/// discovery playlist. The analyzer/server build generates it, and `/settings` is
/// GET-only (no client→server push), so — like the sonic-radio dial and the
/// Ontdekkingen digest — the controls live here, not in the client apps.
@MainActor
struct DiscoverWeeklySettingsView: View {
    @Environment(RoonClient.self) private var client

    @State private var enabled = true
    @State private var intervalDays = 7
    @State private var trackCount = 30
    @State private var exclusionDays = 30
    @State private var lbEnrich = true
    @State private var current: DiscoverWeeklyPlaylist?
    @State private var refreshing = false

    var body: some View {
        Form {
            Section {
                Toggle("Wekelijkse ontdek-playlist aan", isOn: $enabled)
                    .onChange(of: enabled) { _, v in client.discoverWeeklyEnabled = v }
                Text("Een verse selectie uit je eigen bibliotheek: tracks die passen bij wat je veel speelt, maar die je de laatste tijd links liet liggen — via CLAP-klankgelijkenis, volledig lokaal.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Afstemming") {
                Stepper("Ververst elke \(intervalDays) dag\(intervalDays == 1 ? "" : "en")",
                        value: $intervalDays, in: 1...30)
                    .onChange(of: intervalDays) { _, v in client.discoverWeeklyIntervalDays = v }
                Stepper("Aantal tracks: \(trackCount)", value: $trackCount, in: 10...60, step: 5)
                    .onChange(of: trackCount) { _, v in client.discoverWeeklyTrackCount = v }
                Stepper("Sluit tracks uit die je de laatste \(exclusionDays) dag\(exclusionDays == 1 ? "" : "en") speelde",
                        value: $exclusionDays, in: 0...90, step: 1)
                    .onChange(of: exclusionDays) { _, v in client.discoverWeeklyExclusionDays = v }
            }

            Section("Verrijking") {
                Toggle("Aanvullen met ListenBrainz", isOn: $lbEnrich)
                    .onChange(of: lbEnrich) { _, v in client.discoverWeeklyListenBrainzEnrich = v }
                Text("Mengt een paar ListenBrainz-aanbevelingen bij — maar alleen tracks die in je bibliotheek of op Qobuz bestaan. Niet-bezeten tracks worden als ‘nog niet in je bibliotheek’ gelabeld; de rest wordt overgeslagen.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Status") {
                if let current {
                    Label("\(current.weekKey): \(current.tracks.count) tracks (\(current.discoveryCount) buiten je bibliotheek)",
                          systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Nog geen playlist gebouwd.").font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    Task {
                        refreshing = true
                        current = await client.refreshDiscoverWeekly()
                        refreshing = false
                    }
                } label: {
                    if refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Nu genereren / verversen", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(refreshing)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Ontdek Wekelijks")
        #if os(macOS)
        .frame(minWidth: 460)
        #endif
        .task { await load() }
    }

    private func load() async {
        enabled = client.discoverWeeklyEnabled
        intervalDays = client.discoverWeeklyIntervalDays
        trackCount = client.discoverWeeklyTrackCount
        exclusionDays = client.discoverWeeklyExclusionDays
        lbEnrich = client.discoverWeeklyListenBrainzEnrich
        current = await client.discoverWeekly()
    }
}
