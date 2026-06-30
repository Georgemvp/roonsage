import SwiftUI
import RoonSageCore

/// Built on `List`/`Section` end-to-end (not a `VStack` wrapping a `ScrollView`
/// or nested `List`s) — see `GenerateView` for why a non-`List` root is risky
/// even when an inner tab already used `List`.
@MainActor
public struct TasteProfileView: View {
    public init() {}
    @Environment(RoonClient.self) private var client
    @State private var topArtists: [DatabaseManager.ArtistPlayCount] = []
    @State private var recentListens: [DatabaseManager.ListenEntry] = []
    @State private var totalListens: Int = 0
    @State private var distinctArtists: Int = 0
    @State private var analysis: DatabaseManager.TasteAnalysis?
    @State private var isLoaded = false
    @State private var selectedTab: Tab = .analyse
    /// Throttle for the (now analyzer-tag-backed, heavier) profile fetch. `zones`
    /// mutates every ~1.5s while playing — without this, every seek tick fired a
    /// full /taste-analysis + /history reload, piling up in the server's reader
    /// pool. onAppear and the refresh button bypass the throttle (force).
    @State private var lastLoad: Date = .distantPast

    // Last.fm live top-lijsten
    @State private var lfPeriod: LastfmClient.Period = .overall
    @State private var lfKind: LfKind = .artists
    @State private var lfItems: [LastfmClient.TopItem] = []
    @State private var lfLoading = false

    enum Tab: String, CaseIterable {
        case analyse    = "Analyse"
        case topArtists = "Topartiesten"
        case recent     = "Recent gespeeld"
        case lastfm     = "Last.fm top"
    }

    enum LfKind: String, CaseIterable {
        case artists = "Artiesten"
        case tracks  = "Nummers"
        case albums  = "Albums"
    }

    public var body: some View {
        List {
            AsyncStateView(isLoading: !isLoaded, isEmpty: totalListens == 0,
                           onRetry: { load(force: true) }) {
                Section { headerStats }.listRowBackground(Color.clear)
                Section { tabPicker }.listRowBackground(Color.clear)
                tabContent
            } empty: {
                Section { emptyState.listRowBackground(Color.clear) }
                    .listRowSeparator(.hidden)
            }
        }
        .navigationTitle("Smaakprofiel")
        .toolbar {
            Button { load(force: true) } label: { Image(systemName: "arrow.clockwise") }
                .help("Ververs")
                .accessibilityLabel("Ververs")
        }
        .onAppear { load(force: true) }
        .onChange(of: client.zones) { _, _ in load() }
    }

    // MARK: - Header

    var headerStats: some View {
        HStack(spacing: Spacing.xl) {
            VStack(spacing: 2) {
                Text("\(totalListens.formatted())")
                    .font(.title2.bold().monospacedDigit())
                Text("Totaal afgespeeld")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 32)
            VStack(spacing: 2) {
                Text("\(distinctArtists.formatted())")
                    .font(.title2.bold().monospacedDigit())
                Text("Artiesten gehoord")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tab picker

    var tabPicker: some View {
        Picker("Tab", selection: $selectedTab) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Tab content

    @ViewBuilder
    var tabContent: some View {
        switch selectedTab {
        case .analyse:    analyseSections
        case .topArtists: artistsSection
        case .recent:     recentSection
        case .lastfm:     lastfmSections
        }
    }

    // MARK: - Analyse (taste fingerprint)

    @ViewBuilder
    var analyseSections: some View {
        if let a = analysis {
            Section {
                HStack(spacing: Spacing.md) {
                    feedbackChip(icon: "hand.thumbsup.fill", tint: .roonGold,
                                 value: a.likeCount, label: "Likes")
                    feedbackChip(icon: "hand.thumbsdown.fill", tint: .roonDanger,
                                 value: a.dislikeCount, label: "Dislikes")
                }
            }
            .plainCardRow()

            if a.peakHour >= 0 {
                Section {
                    analysisCard("Wanneer je luistert", systemImage: "clock") {
                        barList(a.partsOfDay)
                        Text("Piekuur: rond \(a.peakHour):00")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.top, Spacing.xs)
                    }
                }
                .plainCardRow()
            }

            if !a.topGenres.isEmpty {
                Section {
                    analysisCard("Genres die je het meest hoort", systemImage: "guitars") {
                        barList(a.topGenres)
                    }
                }
                .plainCardRow()
            }

            if let tags = a.topTags, !tags.isEmpty {
                Section {
                    analysisCard("Stijlen & sferen", systemImage: "waveform") {
                        barList(tags)
                    }
                }
                .plainCardRow()
            }

            if !a.topDecades.isEmpty {
                Section {
                    analysisCard("Tijdperken", systemImage: "calendar") {
                        barList(a.topDecades)
                    }
                }
                .plainCardRow()
            }

            if !a.topLikedArtists.isEmpty {
                Section {
                    analysisCard("Je likes wijzen naar", systemImage: "heart") {
                        Text(a.topLikedArtists.joined(separator: " · "))
                            .font(.callout)
                    }
                }
                .plainCardRow()
            }
            if !a.topDislikedArtists.isEmpty {
                Section {
                    analysisCard("Minder van", systemImage: "hand.thumbsdown") {
                        Text(a.topDislikedArtists.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .plainCardRow()
            }
        } else if isLoaded {
            Section {
                ContentUnavailableView("Analyse nog niet beschikbaar", systemImage: "chart.pie",
                                       description: Text("Speel meer muziek — je smaakprofiel groeit vanzelf."))
                .listRowBackground(Color.clear)
            }
            .listRowSeparator(.hidden)
        } else {
            Section { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
        }
    }

    private func feedbackChip(icon: String, tint: Color, value: Int, label: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(value)").font(.title3.bold().monospacedDigit())
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    private func analysisCard<Content: View>(_ title: String, systemImage: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    /// Proportional bars for a labelled-count breakdown (largest = full width).
    @ViewBuilder
    private func barList(_ items: [DatabaseManager.TasteAnalysis.Count]) -> some View {
        let maxCount = max(1, items.map(\.count).max() ?? 1)
        VStack(spacing: Spacing.xs) {
            ForEach(items) { item in
                HStack(spacing: Spacing.sm) {
                    Text(item.label).font(.caption).lineLimit(1)
                        .frame(width: 88, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary).frame(height: 8)
                            Capsule().fill(Color.roonGold)
                                .frame(width: max(4, geo.size.width * CGFloat(item.count) / CGFloat(maxCount)), height: 8)
                        }
                    }
                    .frame(height: 8)
                    Text("\(item.count)").font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Last.fm live top-lijsten

    @ViewBuilder
    var lastfmSections: some View {
        Section {
            Picker("Periode", selection: $lfPeriod) {
                ForEach(LastfmClient.Period.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Soort", selection: $lfKind) {
                ForEach(LfKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .listRowBackground(Color.clear)
        .onChange(of: lfPeriod) { _, _ in loadLastfm() }
        .onChange(of: lfKind) { _, _ in loadLastfm() }
        .task { loadLastfm() }

        if !client.lastfmConfigured {
            Section {
                ContentUnavailableView(
                    "Last.fm niet gekoppeld",
                    systemImage: "link",
                    description: Text("Koppel Last.fm in Instellingen om je top-artiesten, -nummers en -albums te zien."))
                .listRowBackground(Color.clear)
            }
            .listRowSeparator(.hidden)
        } else if lfLoading {
            Section { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
        } else if lfItems.isEmpty {
            Section {
                ContentUnavailableView("Geen gegevens", systemImage: "chart.bar")
                    .listRowBackground(Color.clear)
            }
            .listRowSeparator(.hidden)
        } else {
            Section("Last.fm top") {
                ForEach(lfItems) { item in
                    HStack(spacing: Spacing.md) {
                        Text(item.name).font(.body).lineLimit(1)
                        if let a = item.artist {
                            Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("\(item.playcount)×")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    var artistsSection: some View {
        Section("Topartiesten") {
            ForEach(Array(topArtists.enumerated()), id: \.offset) { index, item in
                HStack(spacing: Spacing.md) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, alignment: .trailing)

                    Text(item.artist)
                        .font(.body)
                        .lineLimit(1)

                    Spacer()

                    Text("\(item.count)× gespeeld")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 2)
            }
        }
    }

    var recentSection: some View {
        Section("Recent gespeeld") {
            ForEach(Array(recentListens.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.title)
                            .font(.body)
                            .lineLimit(1)
                        Spacer()
                        Text(formatDate(entry.playedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    HStack(spacing: Spacing.xs) {
                        if let artist = entry.artist {
                            Text(artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if entry.artist != nil, entry.album != nil {
                            Text("·").font(.caption).foregroundStyle(.tertiary)
                        }
                        if let album = entry.album {
                            Text(album)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        if let zone = entry.zoneName {
                            Spacer()
                            Text(zone)
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Empty state

    var emptyState: some View {
        ContentUnavailableView(
            "Nog geen luistergeschiedenis",
            systemImage: "chart.bar",
            description: Text("Speel muziek via Roon en je smaakprofiel bouwt zich hier vanzelf op.")
        )
    }

    // MARK: - Helpers

    private func load(force: Bool = false) {
        // Throttle automatic (zones-driven) reloads; appear + refresh force through.
        if !force, Date().timeIntervalSince(lastLoad) < 20 { return }
        lastLoad = Date()
        Task {
            // One combined fetch — in thin-client mode this pulls the taste
            // profile live from the server (the local DB has no history).
            guard let snap = await client.tasteProfile(topLimit: 50, recentLimit: 100) else {
                // Transient failure: keep last-known data, don't flash the empty
                // state. The view reloads on the next zone change / poll.
                return
            }
            totalListens   = snap.total
            // True distinct-artist count; fall back to the (capped) top list for
            // an older server that didn't send it.
            distinctArtists = snap.distinctArtists ?? snap.topArtists.count
            topArtists     = snap.topArtists
            recentListens  = snap.recent
            isLoaded = true
        }
        Task {
            if let a = await client.tasteAnalysis() { analysis = a }
        }
    }

    private func loadLastfm() {
        guard client.lastfmConfigured else { lfItems = []; return }
        let period = lfPeriod
        let kind = lfKind
        lfLoading = true
        Task {
            let items: [LastfmClient.TopItem]
            switch kind {
            case .artists: items = await client.lastfmTopArtists(period: period, limit: 50)
            case .tracks:  items = await client.lastfmTopTracks(period: period, limit: 50)
            case .albums:  items = await client.lastfmTopAlbums(period: period, limit: 50)
            }
            // Negeer als de selectie tijdens het laden veranderde.
            guard period == lfPeriod, kind == lfKind else { return }
            lfItems = items
            lfLoading = false
        }
    }

    private func formatDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }
}
