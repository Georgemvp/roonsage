import RoonSageCore
import RoonSageUI
import SwiftUI

/// Controls the Qobuz radio mirror: a master on/off switch plus a per-radio
/// allow-list. Checked = mirrored to Qobuz. The server's auto-sync (every 3h)
/// honours exactly this selection; an empty selection clears the Qobuz mirror.
@MainActor
struct SonicRadioSettingsView: View {
    @Environment(RoonClient.self) private var client

    @State private var enabled = true
    @State private var selected: Set<String> = []
    @State private var radiosByCat: [RoonClient.RadioCategory: [RoonClient.RadioDescriptor]] = [:]
    @State private var loading = true
    @State private var syncing = false
    @State private var status = ""

    var body: some View {
        Form {
            Section {
                Toggle("Synchroniseer sonische radio's naar Qobuz", isOn: $enabled)
                    .onChange(of: enabled) { _, new in client.radioSyncEnabled = new }
                Text("Aan: de server houdt de aangevinkte radio's automatisch up-to-date op Qobuz (elke 3 uur). Uit: er wordt niets naar Qobuz geschreven.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !client.qobuzConfigured {
                Section {
                    Label("Qobuz is niet ingesteld — vul je inloggegevens in onder Server.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if enabled {
                if loading {
                    Section {
                        HStack(spacing: Spacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("Beschikbare radio's laden…")
                        }
                    }
                } else if radiosByCat.values.allSatisfy(\.isEmpty) {
                    Section {
                        Text("Nog geen radio's beschikbaar — analyseer en tag eerst meer muziek.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(RoonClient.RadioCategory.allCases) { cat in
                        if let radios = radiosByCat[cat], !radios.isEmpty {
                            Section(cat.label) {
                                ForEach(radios) { r in
                                    Toggle(isOn: binding(for: r.id)) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(r.label)
                                            Text("\(r.trackCount) nummers")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Section {
                        Button {
                            Task { await syncNow() }
                        } label: {
                            Label(syncing ? "Synchroniseren…" : "Synchroniseer nu",
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(syncing || !client.qobuzConfigured)
                        if !status.isEmpty {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(selected.count) radio('s) geselecteerd.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Radio's")
        #if os(macOS)
        .frame(minWidth: 460)
        #endif
        .task { await load() }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { on in
                if on { selected.insert(id) } else { selected.remove(id) }
                // Persist the explicit allow-list so auto-sync mirrors exactly this.
                client.radioSyncSelection = selected
            })
    }

    private func load() async {
        enabled = client.radioSyncEnabled
        selected = client.currentRadioSelection()
        loading = true
        var map: [RoonClient.RadioCategory: [RoonClient.RadioDescriptor]] = [:]
        for cat in RoonClient.RadioCategory.allCases {
            map[cat] = await client.availableRadios(category: cat)
        }
        radiosByCat = map
        loading = false
    }

    private func syncNow() async {
        syncing = true; defer { syncing = false }
        // Make the auto-sync honour exactly what's shown here.
        client.radioSyncSelection = selected
        status = "Synchroniseren met Qobuz…"
        let n = await client.syncSelectedRadiosToQobuz(selected)
        status = n > 0
            ? "\(n) radio('s) gesynchroniseerd naar Qobuz ✓"
            : "Niets gesynchroniseerd — controleer je Qobuz-login en selectie."
    }
}
