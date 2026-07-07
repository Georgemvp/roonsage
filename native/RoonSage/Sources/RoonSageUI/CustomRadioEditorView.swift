import RoonSageCore
import SwiftUI

/// Compose or edit a custom sonic radio (`RadioConfig`). A `Form`/`List` of facet
/// pickers: large sets (artists, nummers, genres) push a searchable multi-select;
/// small fixed sets (sferen, activiteiten, decennia) are inline checkmark rows.
/// The engine unions the chosen facets into one sound and AND-gates the measured
/// ones (genre/mood/activity/decade) with relaxation — see RoonClient+CustomRadio.
@MainActor
struct CustomRadioEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config: RadioConfig
    private let options: RoonClient.RadioFacetOptions
    private let onSave: (RadioConfig) async -> Bool
    private let isNew: Bool

    @State private var saving = false

    init(config: RadioConfig, options: RoonClient.RadioFacetOptions,
         onSave: @escaping (RadioConfig) async -> Bool) {
        _config = State(initialValue: config)
        self.options = options
        self.onSave = onSave
        self.isNew = config.name.isEmpty && !config.hasFacets
    }

    var body: some View {
        Form {
            Section("Naam") {
                TextField("Bijv. Zomeravond of Focus-house", text: $config.name)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
            }

            Section {
                facetLink(title: "Artiesten", systemImage: "music.mic",
                          options: options.artists.map { .init(key: $0, label: $0) },
                          selection: $config.artists.asSet)
                facetLink(title: "Nummers", systemImage: "music.note",
                          options: options.tracks, selection: $config.trackKeys.asSet)
                facetLink(title: "Genres", systemImage: "guitars",
                          options: options.genres, selection: $config.genres.asSet)
            } header: {
                Text("Bron — seeds")
            } footer: {
                Text("Artiesten en nummers bepalen de klank van de radio. Ze worden niet als filter gebruikt, maar sturen de sfeer.")
            }

            if !options.moods.isEmpty {
                Section("Sfeer") { chipRows(options.moods, selection: $config.moods.asSet) }
            }
            Section("Activiteit") { chipRows(options.activities, selection: $config.activities.asSet) }
            if !options.decades.isEmpty {
                Section("Decennium") { decadeRows }
            }

            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text("Avontuurlijkheid").font(.subheadline)
                        Spacer()
                        Text(adventureLabel).font(.caption).foregroundStyle(Color.roonGold)
                    }
                    Slider(value: $config.adventurousness, in: 0...1, step: 0.05).tint(Color.roonGold)
                }
                Stepper("Aantal tracks: \(config.targetCount)", value: $config.targetCount, in: 8...100, step: 1)
            } header: {
                Text("Afstemming")
            } footer: {
                Text("Genre, sfeer, activiteit en decennium werken als filter (met verzachting): alleen tracks die eraan voldoen komen erin, tenzij er te weinig zijn.")
            }

            Section("Synchronisatie") {
                Toggle("Radio aan", isOn: $config.enabled)
                Toggle("Automatisch naar Qobuz synchroniseren", isOn: $config.syncToQobuz)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "Nieuwe radio" : "Radio bewerken")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Annuleer") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Bewaar") { save() }
                    .disabled(!canSave || saving)
            }
        }
    }

    private var canSave: Bool {
        !config.name.trimmingCharacters(in: .whitespaces).isEmpty && config.hasFacets
    }

    private var adventureLabel: String {
        switch config.adventurousness {
        case ..<0.2:  return "Vooral bekend"
        case ..<0.45: return "Lichte verkenning"
        case ..<0.7:  return "Verkennend"
        default:      return "Op ontdekking"
        }
    }

    // MARK: Facet controls

    private func facetLink(title: String, systemImage: String,
                           options: [RoonClient.FacetOption],
                           selection: Binding<Set<String>>) -> some View {
        NavigationLink {
            FacetMultiSelectView(title: title, options: options, selection: selection)
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(selection.wrappedValue.isEmpty ? "Geen" : "\(selection.wrappedValue.count)")
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(options.isEmpty)
    }

    private func chipRows(_ options: [RoonClient.FacetOption], selection: Binding<Set<String>>) -> some View {
        ForEach(options) { opt in
            Button {
                Haptics.tap()
                if selection.wrappedValue.contains(opt.key) { selection.wrappedValue.remove(opt.key) }
                else { selection.wrappedValue.insert(opt.key) }
            } label: {
                HStack {
                    Text(opt.label)
                    Spacer()
                    if selection.wrappedValue.contains(opt.key) {
                        Image(systemName: "checkmark").foregroundStyle(Color.roonGold)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var decadeRows: some View {
        ForEach(options.decades, id: \.self) { d in
            Button {
                Haptics.tap()
                if let i = config.decades.firstIndex(of: d) { config.decades.remove(at: i) }
                else { config.decades.append(d) }
            } label: {
                HStack {
                    Text(d >= 2000 ? "Jaren \(d)" : "Jaren \(d % 100)")
                    Spacer()
                    if config.decades.contains(d) { Image(systemName: "checkmark").foregroundStyle(Color.roonGold) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func save() {
        guard canSave, !saving else { return }
        Haptics.tap()
        saving = true
        Task {
            let ok = await onSave(config)
            saving = false
            if ok { dismiss() }
        }
    }
}

/// Searchable multi-select over a large facet (artists / nummers / genres).
/// Shared by the custom-radio editor and the Generate seed pickers.
@MainActor
struct FacetMultiSelectView: View {
    let title: String
    let options: [RoonClient.FacetOption]
    @Binding var selection: Set<String>
    @State private var query = ""

    var body: some View {
        List {
            if !selection.isEmpty {
                Section("Gekozen (\(selection.count))") {
                    Button("Selectie wissen", role: .destructive) { selection.removeAll() }
                        .font(.caption)
                }
            }
            Section {
                ForEach(filtered) { opt in
                    Button { toggle(opt.key) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(opt.label).lineLimit(1)
                                if let s = opt.subtitle, !s.isEmpty {
                                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if selection.contains(opt.key) {
                                Image(systemName: "checkmark").foregroundStyle(Color.roonGold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $query, prompt: "Zoeken")
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var filtered: [RoonClient.FacetOption] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return options }
        return options.filter {
            $0.label.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false)
        }
    }

    private func toggle(_ key: String) {
        Haptics.tap()
        if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
    }
}

/// Bridge a `[String]` config facet to the `Set<String>` the pickers bind to,
/// preserving nothing about order (facets are unordered sets semantically).
extension Binding where Value == [String] {
    var asSet: Binding<Set<String>> {
        Binding<Set<String>>(
            get: { Set(wrappedValue) },
            set: { wrappedValue = Array($0) }
        )
    }
}
