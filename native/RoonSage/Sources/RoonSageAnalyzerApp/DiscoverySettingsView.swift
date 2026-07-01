import RoonSageCore
import RoonSageUI
import SwiftUI

/// Tuning for the outward-facing Ontdekkingen engine — the analyzer builds the
/// daily pipeline run, so (like the sonic-radio dial) the controls live here,
/// not in the Mac/iOS client apps. `/settings` is GET-only (no client→server
/// push), so there is exactly one place these are configured.
@MainActor
struct DiscoverySettingsView: View {
    @Environment(RoonClient.self) private var client

    @State private var adventurousness: Double = RoonClient.defaultAdventurousness
    @State private var disabled: Set<String> = []
    @State private var cooldownDays: Int = 60
    @State private var digestWeekday: Int = 2
    @State private var lastDigest: DiscoveryDigestStatus?

    /// Dutch weekday names, indexed by `Calendar` weekday numbering (1 = Sunday).
    private static let weekdayNames = ["", "Zondag", "Maandag", "Dinsdag", "Woensdag", "Donderdag", "Vrijdag", "Zaterdag"]

    var body: some View {
        Form {
            Section("Afstemming") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Veilig ↔ avontuurlijk")
                        Spacer()
                        Text(adventureLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Slider(value: $adventurousness, in: 0...1, step: 0.05)
                        .onChange(of: adventurousness) { _, new in client.discoveryAdventurousness = new }
                    HStack {
                        Text("Veilig").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text("Avontuurlijk").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Text("Veilig weegt zwaarder mee wat meerdere bronnen het eens zijn en past bij je genres. Avontuurlijk geeft meer ruimte aan verwante-maar-nieuwe vondsten en de AI-suggesties. Geldt vanaf de volgende run.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Bronnen") {
                ForEach(RoonClient.discoveryProducers, id: \.id) { producer in
                    Toggle(isOn: binding(for: producer.id)) {
                        Text(DiscoveryProducerLabel.nl(producer.id))
                    }
                }
                Text("Uitgezette bronnen leveren geen aanbevelingen meer aan. Zet je ze allemaal uit, dan draaien tijdelijk toch alle bronnen — Ontdekkingen blijft zo altijd gevuld.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Herhaling") {
                Stepper("Afgewezen pas opnieuw tonen na \(cooldownDays) dagen",
                        value: $cooldownDays, in: 7...180, step: 1)
                    .onChange(of: cooldownDays) { _, new in client.discoveryRejectionCooldownDays = new }
            }

            Section("Wekelijkse digest") {
                Picker("Bouwdag", selection: $digestWeekday) {
                    ForEach(1...7, id: \.self) { day in
                        Text(Self.weekdayNames[day]).tag(day)
                    }
                }
                .onChange(of: digestWeekday) { _, new in client.discoveryDigestWeekday = new }
                if let lastDigest, let week = lastDigest.week {
                    if lastDigest.count > 0, let name = lastDigest.playlistName {
                        Label("Week \(week): \(lastDigest.count) albums naar '\(name)'", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Week \(week): geen wachtende albums om te bundelen", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Nog geen digest gebouwd.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Bundelt op de gekozen dag de sterkste nog-wachtende albumaanbevelingen van de afgelopen week in één Qobuz-playlist. Clients tonen een lokale melding zodra ze een nieuwe week zien.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Ontdekkingen")
        #if os(macOS)
        .frame(minWidth: 460)
        #endif
        .task { await load() }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !disabled.contains(id) },
            set: { on in
                if on { disabled.remove(id) } else { disabled.insert(id) }
                client.discoveryDisabledProducers = disabled
            })
    }

    private var adventureLabel: String {
        switch adventurousness {
        case ..<0.2:  return "Veilig"
        case ..<0.45: return "Lichte verkenning"
        case ..<0.7:  return "Verkennend"
        default:      return "Avontuurlijk"
        }
    }

    private func load() async {
        adventurousness = client.discoveryAdventurousness
        disabled = client.discoveryDisabledProducers
        cooldownDays = client.discoveryRejectionCooldownDays
        digestWeekday = client.discoveryDigestWeekday
        lastDigest = client.discoveryLastDigest
    }
}
