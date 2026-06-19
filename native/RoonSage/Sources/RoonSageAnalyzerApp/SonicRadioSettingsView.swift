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

    // Smart-radio tuning for THIS (server-of-record) build — the analyzer builds
    // the Qobuz radios, so the dial must live here too, not only in the client app.
    @State private var adventurousness: Double = RoonClient.defaultAdventurousness
    @State private var hardBan = false

    var body: some View {
        Form {
            Section {
                Toggle("Synchroniseer sonische radio's naar Qobuz", isOn: $enabled)
                    .onChange(of: enabled) { _, new in client.radioSyncEnabled = new }
                Text("Aan: de server houdt de aangevinkte radio's automatisch up-to-date op Qobuz (elke 3 uur). Uit: er wordt niets naar Qobuz geschreven.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Afstemming") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Avontuurlijkheid")
                        Spacer()
                        Text(adventureLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Slider(value: $adventurousness, in: 0...1, step: 0.05)
                        .onChange(of: adventurousness) { _, new in client.radioAdventurousness = new }
                    HStack {
                        Text("Vertrouwd").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text("Op ontdekking").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Toggle("Verberg tracks met duim-omlaag volledig", isOn: $hardBan)
                    .onChange(of: hardBan) { _, new in client.radioHardBanDisliked = new }
                Text("Bepaalt hoe ver de door de server gebouwde radio's (incl. de Qobuz-mirror) van je vertrouwde muziek durven afdwalen, en of afgekeurde tracks helemaal verdwijnen.")
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

    private var adventureLabel: String {
        switch adventurousness {
        case ..<0.2:  return "Vooral bekend"
        case ..<0.45: return "Lichte verkenning"
        case ..<0.7:  return "Verkennend"
        default:      return "Op ontdekking"
        }
    }

    private func load() async {
        enabled = client.radioSyncEnabled
        selected = client.currentRadioSelection()
        adventurousness = client.radioAdventurousness
        hardBan = client.radioHardBanDisliked
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
