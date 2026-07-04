import RoonSageCore
import SwiftUI

/// Multitag (muffon-style): stack several genres — and optionally a decade — to
/// narrow the library to exactly the crossover you want. The "alle genres"
/// toggle switches between *any-of* (OR) and *all-of* (AND, true multitag), the
/// latter surfacing tracks that sit at the intersection of tags. Runs entirely on
/// the local cache via `filterTracks`; results are instantly playable.
@MainActor
struct MultitagView: View {
    @Environment(RoonClient.self) private var client

    @State private var genres: [String] = []
    @State private var selected: Set<String> = []
    @State private var decade: Int? = nil
    @State private var matchAll = true
    @State private var results: [TrackRecord] = []
    @State private var loading = false
    @State private var searched = false

    private let decades = [1960, 1970, 1980, 1990, 2000, 2010, 2020]

    var body: some View {
        List {
            Section {
                Text("Kies twee of meer genres om de kruising te vinden. Met ‘alle genres’ aan moet een nummer élk gekozen genre hebben.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Alle genres (kruising)", isOn: $matchAll)
            }

            Section("Genres\(selected.isEmpty ? "" : " (\(selected.count))")") {
                if genres.isEmpty {
                    ProgressView()
                } else {
                    ChipGrid(items: genres, selected: selected) { g in
                        if selected.contains(g) { selected.remove(g) } else { selected.insert(g) }
                    }
                    .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.md,
                                              bottom: Spacing.sm, trailing: Spacing.md))
                }
            }

            Section("Decennium") {
                Picker("Decennium", selection: $decade) {
                    Text("Alle").tag(Int?.none)
                    ForEach(decades, id: \.self) { d in Text("\(d)s").tag(Int?.some(d)) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button {
                    runSearch()
                } label: {
                    Label(loading ? "Zoeken…" : "Zoek nummers", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Color.roonGold)
                .disabled(selected.isEmpty || loading)
            }

            if searched {
                if loading {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                } else if results.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Geen kruising gevonden",
                            systemImage: "square.on.square.dashed",
                            description: Text("Deze combinatie levert niks op. Zet ‘alle genres’ uit voor een bredere match, of kies andere genres."))
                        .listRowBackground(Color.clear)
                    }
                } else {
                    resultsSection
                }
            }
        }
        .navigationTitle("Multitag")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task {
            if genres.isEmpty { genres = await client.allGenres(limit: 120) }
        }
    }

    private var resultsSection: some View {
        Section("Resultaten (\(results.count))") {
            HStack(spacing: Spacing.sm) {
                if client.selectedZone != nil {
                    Button {
                        Haptics.success()
                        if let zone = client.selectedZone {
                            Task { await client.curateTracks(Array(results.prefix(60)), zoneID: zone.id) }
                        }
                    } label: { Label("Speel", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(Color.roonGold)
                }
                LocalPlayButton { Array(results.prefix(60)) }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
            }
            ForEach(results.prefix(80), id: \.id) { t in
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.callout).lineLimit(1)
                    if let a = t.artist { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                .contextMenu { PlayActionsMenu(fetch: { [t] }) }
            }
        }
    }

    private func runSearch() {
        guard !selected.isEmpty, !loading else { return }
        Haptics.tap()
        loading = true
        searched = true
        var opts = DatabaseManager.FilterOptions()
        opts.genres = Array(selected)
        opts.matchAllGenres = matchAll
        if let decade { opts.decades = [decade] }
        opts.limit = 300
        Task {
            let r = await client.filterTracks(options: opts)
            await MainActor.run { results = r; loading = false }
        }
    }
}

/// Wrapping selectable chip grid (genres). Kept local to Multitag; a general
/// flow-layout helper can absorb this later.
private struct ChipGrid: View {
    let items: [String]
    let selected: Set<String>
    let onTap: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: Spacing.xs)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.xs) {
            ForEach(items, id: \.self) { g in
                let on = selected.contains(g)
                Button { onTap(g) } label: {
                    Text(g)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, Spacing.sm).padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(on ? Color.roonGold.opacity(0.25) : Color.primary.opacity(0.06),
                                    in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Color.roonGold : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
