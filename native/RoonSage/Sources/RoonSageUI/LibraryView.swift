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
    @State private var viewMode: ViewMode = .tracks
    @State private var selection = Set<String>()
    @State private var showSaveSheet = false
    @State private var newPlaylistName = ""

    /// Library browsing modes: a flat track list, or a grid of albums / artists.
    enum ViewMode: String, CaseIterable, Identifiable {
        case tracks, albums, artists
        var id: String { rawValue }
        var label: String {
            switch self { case .tracks: "Tracks"; case .albums: "Albums"; case .artists: "Artiesten" }
        }
        var icon: String {
            switch self {
            case .tracks: "music.note.list"; case .albums: "square.grid.2x2"; case .artists: "person.2"
            }
        }
    }

    private let gridColumns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.lg)]

    enum SortField: String, CaseIterable, Identifiable {
        case title = "Title", artist = "Artist", album = "Album", year = "Year", bpm = "BPM", random = "Random"
        var id: String { rawValue }
        /// Weergavenaam (NL); rawValue blijft het stabiele ID.
        var label: String {
            switch self {
            case .title: "Titel"; case .artist: "Artiest"; case .album: "Album"
            case .year: "Jaar"; case .bpm: "BPM"; case .random: "Willekeurig"
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
            case .tracks:  tracksContent
            case .albums:  albumsContent
            case .artists: artistsContent
            }
        }
        .animation(Motion.quick, value: selection.isEmpty)
        .navigationDestination(for: DatabaseManager.AlbumResult.self) { AlbumDetailView(album: $0) }
        .navigationDestination(for: DatabaseManager.ArtistResult.self) { ArtistDetailView(artist: $0) }
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
            isSearching = true
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !Task.isCancelled { reloadContent() }
            }
        }
        .onChange(of: selectedTag) { _, _ in reloadTracks() }
        .onChange(of: sort) { _, _ in displayTracks = Self.sortAndDedupe(tracks, by: sort) }
        .onChange(of: viewMode) { _, _ in reloadContent() }
        .onChange(of: client.trackCount) { _, _ in reload() }
        .onAppear { reload() }
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

    private var modePicker: some View {
        Picker("Weergave", selection: $viewMode) {
            ForEach(ViewMode.allCases) { mode in
                Label(mode.label, systemImage: mode.icon).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    private var searchPrompt: String {
        switch viewMode {
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
                LibraryTrackRow(track: track, canPlay: client.selectedZone != nil) {
                    play([asRecord(track)])
                }
                .contextMenu { rowMenu(track) }
                .tag(track.id)
            }
            .refreshable { await refresh() }
            if !selection.isEmpty { selectionBar }
        }
    }

    @ViewBuilder
    private var albumsContent: some View {
        if albums.isEmpty {
            if isLoadingGrid { SkeletonRows() } else { gridEmptyState(noun: "albums") }
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: Spacing.lg) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) { AlbumGridCell(album: album) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Speel album") { playAlbum(album) }
                                    .disabled(client.selectedZone == nil)
                            }
                    }
                }
                .padding(Spacing.lg)
            }
            .refreshable { await refresh() }
        }
    }

    @ViewBuilder
    private var artistsContent: some View {
        if artists.isEmpty {
            if isLoadingGrid { SkeletonRows() } else { gridEmptyState(noun: "artiesten") }
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: Spacing.lg) {
                    ForEach(artists) { artist in
                        NavigationLink(value: artist) { ArtistGridCell(artist: artist) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Speel artiest") { playArtist(artist) }
                                    .disabled(client.selectedZone == nil)
                            }
                    }
                }
                .padding(Spacing.lg)
            }
            .refreshable { await refresh() }
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

    private func playAlbum(_ album: DatabaseManager.AlbumResult) {
        guard let zone = client.selectedZone else { return }
        Haptics.tap()
        Task { await client.playAlbum(albumKey: album.albumKey, zoneID: zone.id) }
    }

    private func playArtist(_ artist: DatabaseManager.ArtistResult) {
        guard let zone = client.selectedZone else { return }
        Haptics.tap()
        Task { await client.playArtist(name: artist.name, zoneID: zone.id) }
    }

    // MARK: - Selection action bar

    private var selectionBar: some View {
        HStack(spacing: Spacing.md) {
            Text("\(selection.count) geselecteerd").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button { play(selectedRecords()) } label: { Label("Speel", systemImage: "play.fill") }
                .disabled(client.selectedZone == nil)
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
        let hasZone = client.selectedZone != nil
        Button("Speel nu") { play([rec]) }.disabled(!hasZone)
        Button("Speel hierna") { queue([rec], next: true) }.disabled(!hasZone)
        Button("Zet in wachtrij") { queue([rec]) }.disabled(!hasZone)
        Divider()
        Button("Start Sonic Radio") {
            guard let zone = client.selectedZone else { return }
            Task { await client.playSonicRadio(title: track.title, artist: track.artist, album: track.album, zoneID: zone.id) }
        }.disabled(!hasZone)
        Divider()
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
        guard let zone = client.selectedZone, !tracks.isEmpty else { return }
        Haptics.tap()
        Task { await client.curateTracks(tracks, zoneID: zone.id) }
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
        Task { tags = await client.topTags(limit: 28) }
        reloadContent()
    }

    /// Loads data for whichever browse mode is active.
    private func reloadContent() {
        switch viewMode {
        case .tracks:  reloadTracks()
        case .albums:  loadAlbums()
        case .artists: loadArtists()
        }
    }

    private func reloadTracks() {
        let q = searchText, tag = selectedTag, currentSort = sort
        if tracks.isEmpty { isLoadingTracks = true }
        Task {
            let rows = await client.browseTracks(query: q, tag: tag)
            let display = await Task.detached { Self.sortAndDedupe(rows, by: currentSort) }.value
            tracks = rows
            displayTracks = display
            isLoadingTracks = false
            isSearching = false
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
        case .tracks:
            let rows = await client.browseTracks(query: searchText, tag: selectedTag)
            let currentSort = sort
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
                .help(canPlay ? "Speel nu" : "Kies eerst een zone")
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
