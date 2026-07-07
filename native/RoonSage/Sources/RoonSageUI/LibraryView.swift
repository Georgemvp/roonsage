import RoonSageCore
import SwiftUI

@MainActor
public struct LibraryView: View {
    public init() {}
    @Environment(RoonClient.self) private var client
    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var tracks: [DatabaseManager.LibraryTrackRow] = []
    @State private var albums: [DatabaseManager.AlbumResult] = []
    @State private var artists: [DatabaseManager.ArtistResult] = []
    @State private var tags: [(tag: String, count: Int)] = []
    @State private var isLoadingTracks = false
    @State private var isLoadingGrid = false
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var sort: SortField = .title
    @State private var viewMode: ViewMode = .overview
    /// Grid filter: only starred albums/artists (LMS "Starred" browse mode).
    @State private var favoritesOnly = false
    @State private var selection = Set<String>()
    @State private var showSaveSheet = false
    @State private var newPlaylistName = ""
    @State private var infoTrack: DatabaseManager.LibraryTrackRow?
    @State private var similarSeed: SonicSeed?

    // Overview landing state — loaded once (guarded by `overviewLoaded`) and
    // refreshed when the library re-syncs (via `reload()` on `client.trackCount`).
    @State private var stats: DatabaseManager.LibraryStats?
    @State private var analyzedTotal = 0
    @State private var analyzedMatched = 0
    @State private var librarySeconds: Double = 0
    @State private var recentlyAdded: [DatabaseManager.LibraryTrackRow] = []
    @State private var recentPlayed: [DatabaseManager.LibraryTrackRow] = []
    @State private var undiscovered: [DatabaseManager.AlbumResult] = []
    @State private var topTracks: [TrackRecord] = []
    @State private var forgotten: [TrackRecord] = []
    @State private var stations: [RoonClient.SonicRadio] = []
    @State private var facets: RoonClient.RadioFacetOptions?
    @State private var overviewLoaded = false

    /// Library modes: an overview landing, then the flat track list / album / artist grids.
    enum ViewMode: String, CaseIterable, Identifiable {
        case overview, tracks, albums, artists
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overview: "Overzicht"; case .tracks: "Tracks"
            case .albums: "Albums"; case .artists: "Artiesten"
            }
        }
        var icon: String {
            switch self {
            case .overview: "house"; case .tracks: "music.note.list"
            case .albums: "square.grid.2x2"; case .artists: "person.2"
            }
        }
    }

    private let gridColumns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.lg)]

    enum SortField: String, CaseIterable, Identifiable {
        case title = "Title", artist = "Artist", album = "Album", year = "Year", bpm = "BPM", random = "Random"
        // LMS-style browse modes: these rank the *dataset* (SQL / play stats),
        // not the fetched page — see reloadTracks.
        case recentlyAdded = "RecentlyAdded", mostPlayed = "MostPlayed", recentlyPlayed = "RecentlyPlayed"
        var id: String { rawValue }
        /// Weergavenaam (NL); rawValue blijft het stabiele ID.
        var label: String {
            switch self {
            case .title: "Titel"; case .artist: "Artiest"; case .album: "Album"
            case .year: "Jaar"; case .bpm: "BPM"; case .random: "Willekeurig"
            case .recentlyAdded: "Recent toegevoegd"
            case .mostPlayed: "Meest gespeeld"
            case .recentlyPlayed: "Recent gespeeld"
            }
        }
        /// Ranking is decided before/while fetching; keep the fetched order.
        var isDatasetRanked: Bool {
            switch self {
            case .recentlyAdded, .mostPlayed, .recentlyPlayed: true
            default: false
            }
        }
    }

    /// Cached sort+dedup result. This used to be a computed property, which
    /// re-ran a localized O(n log n) sort (and reshuffled `.random`!) on every
    /// body evaluation — selection changes, keystrokes, sync ticks. Now it's
    /// recomputed only when `tracks` or `sort` actually change.
    @State private var displayTracks: [DatabaseManager.LibraryTrackRow] = []

    private nonisolated static func sortAndDedupe(
        _ tracks: [DatabaseManager.LibraryTrackRow], by sort: SortField
    ) -> [DatabaseManager.LibraryTrackRow] {
        let sorted: [DatabaseManager.LibraryTrackRow]
        switch sort {
        case .title:  sorted = tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: sorted = tracks.sorted { ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending }
        case .album:  sorted = tracks.sorted { ($0.album ?? "").localizedCaseInsensitiveCompare($1.album ?? "") == .orderedAscending }
        case .year:   sorted = tracks.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
        case .bpm:    sorted = tracks.sorted { ($0.bpm ?? 0) < ($1.bpm ?? 0) }
        case .random: sorted = tracks.shuffled()
        case .recentlyAdded, .mostPlayed, .recentlyPlayed:
            sorted = tracks   // already ranked by the fetch (SQL / play stats)
        }
        // Deduplicate: keep the first occurrence of each artist+title pair so
        // remasters, deluxe editions, and box-set copies don't all show up.
        var seen = Set<String>()
        return sorted.filter { track in
            let key = "\(track.artist?.lowercased() ?? "")|\(track.title.lowercased())"
            return seen.insert(key).inserted
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if client.isSyncing { SyncProgressBanner() }

            modePicker

            switch viewMode {
            case .overview: overviewContent
            case .tracks:  tracksContent
            case .albums:  albumsContent
            case .artists: artistsContent
            }
        }
        .animation(Motion.quick, value: selection.isEmpty)
        .navigationDestination(for: DatabaseManager.AlbumResult.self) { AlbumDetailView(album: $0) }
        .navigationDestination(for: DatabaseManager.ArtistResult.self) { ArtistDetailView(artist: $0) }
        .navigationDestination(for: LibraryFilter.self) { FilteredTracksView(filter: $0) }
        .navigationTitle("Bibliotheek (\(client.trackCount) tracks)")
        .searchable(text: $searchText, prompt: searchPrompt)
        .toolbar {
            ToolbarItem {
                if isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            if viewMode == .tracks {
                ToolbarItem {
                    Picker("Sorteer", selection: $sort) {
                        ForEach(SortField.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .help("Sorteer tracks")
                }
            } else if viewMode == .albums || viewMode == .artists {
                ToolbarItem {
                    Button {
                        favoritesOnly.toggle()
                    } label: {
                        Image(systemName: favoritesOnly ? "star.fill" : "star")
                            .foregroundStyle(favoritesOnly ? Color.roonGold : .secondary)
                    }
                    .accessibilityLabel("Alleen favorieten")
                    .help(favoritesOnly ? "Toon alles" : "Alleen favorieten")
                }
            }
            ToolbarItem {
                if client.isSyncing {
                    Button("Annuleer", role: .cancel) { client.cancelSync() }
                } else {
                    Button { client.startSync() } label: {
                        Label("Synchroniseer bibliotheek", systemImage: "arrow.clockwise")
                    }
                    .disabled(!client.connectionState.isConnected)
                }
            }
            #if os(iOS)
            // Without an edit toggle, `List(selection:)` can't enter multi-select
            // on touch, leaving the Speel/Wachtrij/Bewaar bar unreachable.
            if viewMode == .tracks, !tracks.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton().accessibilityHint("Selecteer meerdere tracks")
                }
            }
            #endif
        }
        .onChange(of: searchText) { _, _ in
            // Searching in the overview jumps to the track browser — the overview has
            // no result list of its own. Clearing search stays put (less surprising).
            if !searchText.isEmpty, viewMode == .overview { viewMode = .tracks }
            isSearching = true
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !Task.isCancelled { reloadContent() }
            }
        }
        .onChange(of: selectedTag) { _, _ in reloadTracks() }
        .onChange(of: sort) { old, new in
            // Dataset-ranked modes need a refetch; switching between local
            // sorts keeps re-sorting the already-fetched page.
            if new.isDatasetRanked || old.isDatasetRanked { reloadTracks() }
            else { displayTracks = Self.sortAndDedupe(tracks, by: new) }
        }
        .onChange(of: viewMode) { _, _ in reloadContent() }
        .onChange(of: client.trackCount) { _, _ in reload() }
        .onAppear { reload() }
        .sheet(item: $infoTrack) { TrackInfoSheet(track: $0) }
        .similarTracksSheet(item: $similarSeed)
        .alert("Bewaar als playlist", isPresented: $showSaveSheet) {
            TextField("Naam playlist", text: $newPlaylistName)
            Button("Annuleer", role: .cancel) {}
            Button("Bewaar") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                client.savePlaylist(name: name, tracks: selectedRecords())
                newPlaylistName = ""
                selection.removeAll()
            }
        } message: {
            Text("Bewaar \(selection.count) geselecteerde track\(selection.count == 1 ? "" : "s") als lokale playlist.")
        }
    }

    // MARK: - Mode switcher + content

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// Four segments + titles overflow a compact iPhone width, so drop to icon-only there.
    private var compactPicker: Bool { hSizeClass == .compact }
    #else
    private var compactPicker: Bool { false }
    #endif

    private var modePicker: some View {
        let picker = Picker("Weergave", selection: $viewMode) {
            ForEach(ViewMode.allCases) { mode in
                Label(mode.label, systemImage: mode.icon).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        return Group {
            if compactPicker {
                picker.labelStyle(.iconOnly)
            } else {
                picker.labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    private var searchPrompt: String {
        switch viewMode {
        case .overview: "Zoek in je bibliotheek…"
        case .tracks:  "Zoek op titel, artiest of album…"
        case .albums:  "Zoek op album of artiest…"
        case .artists: "Zoek op artiest…"
        }
    }

    @ViewBuilder
    private var tracksContent: some View {
        if !tags.isEmpty { tagChips }

        if isLoadingTracks && tracks.isEmpty {
            SkeletonRows()
        } else if tracks.isEmpty && !client.isSyncing {
            emptyState
        } else {
            List(displayTracks, selection: $selection) { track in
                LibraryTrackRow(track: track, canPlay: client.hasActiveOutput) {
                    play([asRecord(track)])
                }
                .contextMenu { rowMenu(track) }
                .tag(track.id)
            }
            .refreshable { await refresh() }
            if !selection.isEmpty { selectionBar }
        }
    }

    /// Grid data after the favorites filter.
    private var visibleAlbums: [DatabaseManager.AlbumResult] {
        guard favoritesOnly else { return albums }
        return albums.filter { client.isFavoriteAlbum(album: $0.album, artist: $0.artist) }
    }

    private var visibleArtists: [DatabaseManager.ArtistResult] {
        guard favoritesOnly else { return artists }
        return artists.filter { client.isFavoriteArtist($0.name) }
    }

    @ViewBuilder
    private var albumsContent: some View {
        AsyncStateView(isLoading: isLoadingGrid, isEmpty: visibleAlbums.isEmpty,
                       onRetry: { reloadContent() }) {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: Spacing.lg) {
                    ForEach(visibleAlbums) { album in
                        NavigationLink(value: album) { AlbumGridCell(album: album) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                PlayActionsMenu(fetch: { [client] in
                                    await client.tracksForAlbum(album.albumKey).map(\.asTrackRecord)
                                })
                            }
                    }
                }
                .padding(Spacing.lg)
            }
            .refreshable { await refresh() }
        } empty: {
            gridEmptyState(noun: "albums")
        }
    }

    @ViewBuilder
    private var artistsContent: some View {
        AsyncStateView(isLoading: isLoadingGrid, isEmpty: visibleArtists.isEmpty,
                       onRetry: { reloadContent() }) {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: Spacing.lg) {
                    ForEach(visibleArtists) { artist in
                        NavigationLink(value: artist) { ArtistGridCell(artist: artist) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                PlayActionsMenu(fetch: { [client] in
                                    var records: [TrackRecord] = []
                                    for album in await client.albumsByArtist(artist.name) {
                                        records += await client.tracksForAlbum(album.albumKey).map(\.asTrackRecord)
                                    }
                                    return records
                                })
                            }
                    }
                }
                .padding(Spacing.lg)
            }
            .refreshable { await refresh() }
        } empty: {
            gridEmptyState(noun: "artiesten")
        }
    }

    @ViewBuilder
    private func gridEmptyState(noun: String) -> some View {
        if client.connectionState.isConnected {
            ContentUnavailableView("Geen \(noun)", systemImage: "square.grid.2x2",
                description: Text(searchText.isEmpty ? "Synchroniseer je bibliotheek." : "Geen \(noun) voor “\(searchText)”."))
        } else {
            ContentUnavailableView("Niet verbonden", systemImage: "wifi.slash",
                description: Text("Verbind eerst met je Roon Core."))
        }
    }

    // MARK: - Selection action bar

    private var selectionBar: some View {
        HStack(spacing: Spacing.md) {
            Text("\(selection.count) geselecteerd").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button { play(selectedRecords()) } label: { Label("Speel", systemImage: "play.fill") }
                .disabled(!client.hasActiveOutput)
            Button { queue(selectedRecords()) } label: { Label("Wachtrij", systemImage: "text.append") }
                .disabled(client.selectedZone == nil)
            Button { showSaveSheet = true } label: { Label("Bewaar", systemImage: "plus.rectangle.on.folder") }
            Button { selection.removeAll() } label: { Label("Wis", systemImage: "xmark") }
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
        .background(.bar)
        .transition(.move(edge: .bottom))
    }

    // MARK: - Per-row context menu

    @ViewBuilder
    private func rowMenu(_ track: DatabaseManager.LibraryTrackRow) -> some View {
        let rec = asRecord(track)
        PlayActionsMenu(fetch: { [rec] })
        Divider()
        Button("Start Sonic Radio") {
            guard let zone = client.selectedZone else { return }
            Task { await client.playSonicRadio(title: track.title, artist: track.artist, album: track.album, zoneID: zone.id) }
        }.disabled(client.selectedZone == nil)
        Button("Sonisch vergelijkbaar", systemImage: "waveform.path.ecg") {
            similarSeed = SonicSeed(title: track.title, artist: track.artist,
                                    album: track.album, imageKey: track.imageKey)
        }
        Divider()
        Button("Info", systemImage: "info.circle") { infoTrack = track }
        Button("Bewaar als playlist…") {
            selection = [track.id]
            showSaveSheet = true
        }
    }

    // MARK: - Helpers

    private func asRecord(_ t: DatabaseManager.LibraryTrackRow) -> TrackRecord {
        TrackRecord(id: t.id, title: t.title, artist: t.artist, album: t.album, year: t.year, isLive: t.isLive)
    }

    private func selectedRecords() -> [TrackRecord] {
        displayTracks.filter { selection.contains($0.id) }.map(asRecord)
    }

    private func play(_ tracks: [TrackRecord]) {
        guard !tracks.isEmpty else { return }
        Haptics.tap()
        // Follow the active output: on-device when "dit apparaat" is chosen, else
        // the selected Roon zone (identical to the old curateTracks path). Queue +
        // Sonic Radio stay zone-only — there's no local equivalent.
        Task { await client.playToActiveOutput(tracks) }
    }

    private func queue(_ tracks: [TrackRecord], next: Bool = false) {
        guard let zone = client.selectedZone, !tracks.isEmpty else { return }
        Haptics.tap()
        Task { await client.queueTracks(tracks, next: next, zoneID: zone.id) }
    }

    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.tag) { item in
                    let isOn = selectedTag == item.tag
                    Button {
                        selectedTag = isOn ? nil : item.tag
                    } label: {
                        Text(item.tag)
                            .font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, Spacing.xs)
                            .background(isOn ? Color.roonGold : Color.platformQuaternaryFill.opacity(0.5),
                                        in: Capsule())
                            // Gold is a light colour — white on gold fails WCAG AA (~2.3:1).
                            .foregroundStyle(isOn ? .black : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, Spacing.sm)
        }
        .background(.bar)
    }

    private func reload() {
        overviewLoaded = false   // a resync (trackCount change) should repopulate the overview
        Task { tags = await client.topTags(limit: 28) }
        Task { await client.ensureFavoritesLoaded() }   // drives the star filter
        reloadContent()
    }

    /// Loads data for whichever browse mode is active.
    private func reloadContent() {
        switch viewMode {
        case .overview: loadOverview()
        case .tracks:  reloadTracks()
        case .albums:  loadAlbums()
        case .artists: loadArtists()
        }
    }

    private func reloadTracks() {
        let q = searchText, tag = selectedTag, currentSort = sort
        if tracks.isEmpty { isLoadingTracks = true }
        Task {
            let rows = await fetchTracks(query: q, tag: tag, sort: currentSort)
            let display = await Task.detached { Self.sortAndDedupe(rows, by: currentSort) }.value
            tracks = rows
            displayTracks = display
            isLoadingTracks = false
            isSearching = false
        }
    }

    /// Fetch honouring the sort mode at the dataset level: play-stat sorts rank
    /// ALL play stats first and resolve the top keys to rows (a page fetched in
    /// artist-order can't be re-sorted into "most played"); recently-added
    /// sorts in SQL via the track_first_seen side table.
    private func fetchTracks(query: String, tag: String?, sort: SortField) async -> [DatabaseManager.LibraryTrackRow] {
        switch sort {
        case .mostPlayed, .recentlyPlayed:
            let stats = await client.playStats()
            let ranked = sort == .mostPlayed
                ? stats.sorted { $0.count > $1.count }
                : stats.sorted { $0.lastPlayed > $1.lastPlayed }
            let keys = ranked.lazy.map(\.matchKey).filter { !$0.isEmpty }
            var rows = await client.tracksByMatchKeys(Array(keys.prefix(400)))
            // Search/tag still apply — filter the ranked rows client-side.
            if !query.isEmpty {
                let needle = query.lowercased()
                rows = rows.filter {
                    $0.title.lowercased().contains(needle)
                        || ($0.artist ?? "").lowercased().contains(needle)
                        || ($0.album ?? "").lowercased().contains(needle)
                }
            }
            if let tag, !tag.isEmpty {
                let t = tag.lowercased()
                rows = rows.filter { $0.tags.contains { $0.lowercased() == t } }
            }
            return Array(rows.prefix(300))
        case .recentlyAdded:
            return await client.browseTracks(query: query, tag: tag, order: .recentlyAdded)
        default:
            return await client.browseTracks(query: query, tag: tag)
        }
    }

    private func loadAlbums() {
        let q = searchText
        if albums.isEmpty { isLoadingGrid = true }
        Task {
            albums = await client.searchAlbums(query: q)
            isLoadingGrid = false
            isSearching = false
        }
    }

    private func loadArtists() {
        let q = searchText
        if artists.isEmpty { isLoadingGrid = true }
        Task {
            artists = await client.searchArtists(query: q)
            isLoadingGrid = false
            isSearching = false
        }
    }

    /// Pull-to-refresh: re-reads the active mode's data from the local cache.
    /// Awaited so the iOS refresh control shows its spinner until data lands.
    private func refresh() async {
        tags = await client.topTags(limit: 28)
        switch viewMode {
        case .overview:
            await refreshOverview()
        case .tracks:
            let currentSort = sort
            let rows = await fetchTracks(query: searchText, tag: selectedTag, sort: currentSort)
            tracks = rows
            displayTracks = await Task.detached { Self.sortAndDedupe(rows, by: currentSort) }.value
        case .albums:
            albums = await client.searchAlbums(query: searchText)
        case .artists:
            artists = await client.searchArtists(query: searchText)
        }
    }

    @ViewBuilder
    var emptyState: some View {
        if client.connectionState.isConnected {
            ContentUnavailableView("Geen passende tracks", systemImage: "music.note.list",
                description: Text(selectedTag != nil ? "Geen tracks met tag “\(selectedTag!)”." : "Synchroniseer je bibliotheek en zoek daarna."))
        } else {
            ContentUnavailableView("Niet verbonden", systemImage: "wifi.slash",
                description: Text("Verbind eerst met je Roon Core."))
        }
    }

    // MARK: - Overview landing

    /// The library landing: a stats hero, recently-added / recently-played shelves,
    /// "voor jou" recommendation shelves, and browse-by tiles. A List-as-feed (like
    /// DiscoveryView) lazily hosts the shelves and dodges the iOS 26 NavigationStack
    /// + custom-ScrollView layout bug.
    @ViewBuilder
    private var overviewContent: some View {
        List {
            if let stats {
                statsHero(stats).plainCardRow()
                if !recentlyAdded.isEmpty {
                    trackShelf("Recent toegevoegd", "clock.badge.plus", recentlyAdded).plainCardRow()
                }
                if !recentPlayed.isEmpty {
                    trackShelf("Onlangs gespeeld", "play.circle", recentPlayed).plainCardRow()
                }
                if !topTracks.isEmpty {
                    recordShelf("Jouw toptracks", "star.fill", topTracks).plainCardRow()
                }
                if !undiscovered.isEmpty {
                    albumShelf("Onontdekte albums", "sparkles", undiscovered).plainCardRow()
                }
                if forgotten.count > 1 {
                    recordShelf("Vergeten favorieten", "clock.arrow.circlepath", forgotten).plainCardRow()
                }
                if !stations.isEmpty {
                    stationShelf.plainCardRow()
                }
                browseTiles.plainCardRow()
                navCard("Ontdek Wekelijks",
                        "Verse ontdekkingen uit je eigen bibliotheek — elke week vernieuwd.",
                        "sparkles") { DiscoverWeeklyView() }.plainCardRow()
                navCard("Mijn radio's", "Jouw zelf samengestelde sonic radio's.",
                        "dot.radiowaves.left.and.right") { CustomRadioView() }.plainCardRow()
                navCard("Aanbevelen", "Beschrijf een vibe → albums uit je bibliotheek.",
                        "wand.and.stars") { RecommendView() }.plainCardRow()
            } else if !overviewLoaded {
                SkeletonRows().plainCardRow()
            } else {
                overviewEmpty.plainCardRow()
            }
        }
        .listStyle(.plain)
        .refreshable { await refreshOverview() }
    }

    // MARK: Overview — hero + shelves

    @ViewBuilder
    private func statsHero(_ stats: DatabaseManager.LibraryStats) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                StatCard(label: "Tracks", value: stats.totalTracks.formatted())
                StatCard(label: "Artiesten", value: stats.totalArtists.formatted())
                StatCard(label: "Albums", value: stats.totalAlbums.formatted())
            }
            HStack(spacing: Spacing.md) {
                if let top = stats.topGenres.first {
                    Label(top.genre.capitalized, systemImage: "guitars.fill")
                }
                if librarySeconds > 0 {
                    Label("\(Int(librarySeconds / 3600).formatted()) uur muziek", systemImage: "clock")
                }
                if analyzedTotal > 0 {
                    Label("\(analyzedMatched * 100 / analyzedTotal)% geanalyseerd", systemImage: "waveform")
                }
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func trackShelf(_ title: String, _ icon: String,
                            _ rows: [DatabaseManager.LibraryTrackRow]) -> some View {
        shelf(title, icon, covers: rows.map(trackCover),
              zoneAvailable: client.selectedZone != nil) { EmptyView() }
    }

    private func recordShelf(_ title: String, _ icon: String, _ recs: [TrackRecord]) -> some View {
        shelf(title, icon, covers: recs.map(recordCover),
              zoneAvailable: client.selectedZone != nil) { EmptyView() }
    }

    private func albumShelf(_ title: String, _ icon: String,
                            _ albums: [DatabaseManager.AlbumResult]) -> some View {
        shelf(title, icon, covers: albums.map(albumCover),
              zoneAvailable: client.selectedZone != nil) { EmptyView() }
    }

    private func trackCover(_ t: DatabaseManager.LibraryTrackRow) -> Cover {
        let rec = asRecord(t)
        return Cover(id: t.id, title: t.title, subtitle: t.artist, imageKey: t.imageKey) {
            Task { await client.playToActiveOutput([rec]) }
        } playLocal: {
            Task { _ = await client.playLocally([rec]) }
        }
    }

    private func recordCover(_ t: TrackRecord) -> Cover {
        Cover(id: t.id, title: t.title, subtitle: t.artist, imageKey: t.imageKey) {
            Task { await client.playToActiveOutput([t]) }
        } playLocal: {
            Task { _ = await client.playLocally([t]) }
        }
    }

    private func albumCover(_ a: DatabaseManager.AlbumResult) -> Cover {
        Cover(id: a.albumKey, title: a.album, subtitle: a.artist, imageKey: a.imageKey) {
            guard let zone = client.selectedZone else { return }
            Task { await client.playAlbum(albumKey: a.albumKey, zoneID: zone.id) }
        } playLocal: {
            Task { _ = await client.playAlbumLocally(albumKey: a.albumKey) }
        }
    }

    // MARK: Overview — sonic radio stations

    private var stationShelf: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Radiostations", "dot.radiowaves.left.and.right") { EmptyView() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.md) {
                    ForEach(stations) { stationTile($0) }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func stationTile(_ radio: RoonClient.SonicRadio) -> some View {
        Button {
            guard let zone = client.selectedZone else { return }
            Haptics.tap()
            Task { await client.startRadio(radio, zoneID: zone.id) }
        } label: {
            VStack(spacing: Spacing.xs) {
                AlbumArtView(imageKey: radio.imageKey, size: 110, cornerRadius: 55)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.caption).foregroundStyle(.white)
                            .padding(6).background(Color.roonGold, in: Circle()).padding(4)
                    }
                Text(radio.artist).font(.caption.weight(.medium)).lineLimit(1)
                Text("Radio").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 110)
        }
        .buttonStyle(.plain)
        .disabled(client.selectedZone == nil)
        .accessibilityLabel("Start radio op \(radio.artist)")
    }

    // MARK: Overview — browse by genre / sfeer / decade

    /// Tappable tiles that deep-link into a filtered library list. Genres + decades
    /// come from `radioFacetOptions()`; "sfeer" reuses the audio-tag vocabulary
    /// (`topTags`) — the CLAP moods aren't a `FilterOptions` dimension, the tags are.
    @ViewBuilder
    private var browseTiles: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("Blader door", "square.grid.2x2") { EmptyView() }
            if let facets, !facets.genres.isEmpty {
                filterChipRow("Genres", facets.genres.prefix(16).map {
                    LibraryFilter(kind: .genre($0.key), title: $0.label.capitalized)
                })
            }
            if !tags.isEmpty {
                filterChipRow("Sfeer", tags.prefix(16).map {
                    LibraryFilter(kind: .tag($0.tag), title: $0.tag.capitalized)
                })
            }
            if let facets, !facets.decades.isEmpty {
                filterChipRow("Decennia", facets.decades.map {
                    LibraryFilter(kind: .decade($0), title: "\($0)s")
                })
            }
        }
    }

    private func filterChipRow(_ heading: String, _ filters: [LibraryFilter]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(heading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(filters, id: \.self) { filter in
                        NavigationLink(value: filter) {
                            Label(filter.title, systemImage: filter.icon)
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Color.platformQuaternaryFill.opacity(0.5), in: Capsule())
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: Overview — Ontdek Wekelijks entry + states

    /// A prominent navigation card into another feature (Ontdek Wekelijks, Mijn
    /// radio's, Aanbevelen) — pushed onto this stack so it works on iOS + macOS alike.
    @ViewBuilder
    private func navCard<Destination: View>(
        _ title: String, _ subtitle: String, _ icon: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .font(.title2).foregroundStyle(Color.roonGold)
                    .frame(width: 44, height: 44)
                    .background(Color.roonGold.opacity(0.15), in: RoundedRectangle(cornerRadius: Radius.lg))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var overviewEmpty: some View {
        ContentUnavailableView(
            client.connectionState.isConnected ? "Nog geen bibliotheek" : "Niet verbonden",
            systemImage: client.connectionState.isConnected ? "music.note.house" : "wifi.slash",
            description: Text(client.connectionState.isConnected
                ? "Synchroniseer je bibliotheek om je overzicht te vullen."
                : "Verbind eerst met je Roon Core."))
    }

    // MARK: Overview — data loading

    private func loadOverview() {
        guard !overviewLoaded else { return }
        overviewLoaded = true
        Task { await performOverviewLoad() }
    }

    private func refreshOverview() async {
        overviewLoaded = true   // keep the onChange guard from double-firing mid-refresh
        await performOverviewLoad()
    }

    /// Stats first (drives the hero + progressive reveal), then the shelves concurrently.
    private func performOverviewLoad() async {
        async let statsV = client.libraryStats()
        async let analyzedV = client.audioFeaturesStats()
        async let durationV = client.libraryDurationSeconds()
        async let addedV = client.browseTracks(query: "", tag: nil, order: .recentlyAdded)
        async let playedV = recentPlayedRows()
        async let undiscV = client.undiscoveredAlbums()
        async let topV = client.topTracks()
        async let forgottenV = client.forgottenFavorites()
        async let stationsV = client.dailyRadios()
        async let facetsV = client.radioFacetOptions()

        stats = await statsV
        let a = await analyzedV
        analyzedTotal = a.total
        analyzedMatched = a.matched
        librarySeconds = await durationV
        recentlyAdded = Array(await addedV.prefix(15))
        recentPlayed = await playedV
        undiscovered = await undiscV
        topTracks = await topV
        forgotten = await forgottenV
        stations = await stationsV
        facets = await facetsV
    }

    /// Recently-played rows *with artwork*: `ListenEntry` carries no image, so rank the
    /// play stats by last-played and resolve the top keys to full library rows.
    private func recentPlayedRows() async -> [DatabaseManager.LibraryTrackRow] {
        let ps = await client.playStats()
        let keys = ps.sorted { $0.lastPlayed > $1.lastPlayed }
            .map(\.matchKey).filter { !$0.isEmpty }
        return await client.tracksByMatchKeys(Array(keys.prefix(15)))
    }
}

// MARK: - Sync progress banner

@MainActor
struct SyncProgressBanner: View {
    @Environment(RoonClient.self) private var client

    public var body: some View {
        let progress = client.syncProgress
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ProgressView(value: progress.fraction).progressViewStyle(.linear)
                Text("\(progress.albumsCompleted)/\(progress.albumsTotal)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }
            Text(progress.phase).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
        .background(.regularMaterial)
    }
}

// MARK: - Track row (with audio features)

struct LibraryTrackRow: View {
    let track: DatabaseManager.LibraryTrackRow
    let canPlay: Bool
    let onPlay: () -> Void

    public var body: some View {
        HStack(spacing: 10) {
            AlbumArtView(imageKey: track.imageKey, size: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(track.title).font(.body).lineLimit(1)
                    if track.isLive {
                        Text("LIVE").font(.caption2.bold()).foregroundStyle(Color.roonWarning)
                    }
                    if let y = track.year {
                        Text(String(y)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 6) {
                    if let a = track.artist {
                        Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let bpm = track.bpm {
                        badge("\(Int(bpm)) BPM")
                    }
                    if let cam = track.camelot, !cam.isEmpty {
                        badge(cam)
                    }
                    if !track.tags.isEmpty {
                        Text(track.tags.prefix(3).joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            Spacer()
            Button(action: onPlay) { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .disabled(!canPlay)
                .accessibilityLabel("Speel nu")
                .help(canPlay ? "Speel nu" : "Kies eerst een zone of apparaat")
        }
        .padding(.vertical, 2)
    }

    /// One coherent VoiceOver announcement per row instead of 4–7 separate atoms.
    private var accessibilityText: String {
        var parts: [String] = [track.title]
        if let a = track.artist, !a.isEmpty { parts.append(a) }
        if track.isLive { parts.append("live") }
        if let y = track.year { parts.append(String(y)) }
        if let bpm = track.bpm { parts.append("\(Int(bpm)) BPM") }
        return parts.joined(separator: ", ")
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }
}

// MARK: - Album grid cell

struct AlbumGridCell: View {
    let album: DatabaseManager.AlbumResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumArtView(imageKey: album.imageKey, size: 150, cornerRadius: Radius.lg)
            Text(album.album).font(.callout).lineLimit(1)
            Text(albumSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(albumSubtitle.isEmpty ? album.album : "\(album.album), \(albumSubtitle)")
    }

    private var albumSubtitle: String {
        var parts: [String] = []
        if let a = album.artist, !a.isEmpty { parts.append(a) }
        if let y = album.year { parts.append(String(y)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Artist grid cell

struct ArtistGridCell: View {
    let artist: DatabaseManager.ArtistResult

    var body: some View {
        VStack(spacing: 6) {
            AlbumArtView(imageKey: artist.imageKey, size: 150, cornerRadius: 75)
            Text(artist.name).font(.callout).lineLimit(1)
            Text("\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s") · \(artist.trackCount) nummers")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(artist.name), \(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s"), \(artist.trackCount) nummers")
    }
}
