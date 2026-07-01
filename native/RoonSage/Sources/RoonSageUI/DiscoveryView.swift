import SwiftUI
import Charts
import RoonSageCore

/// Editorial "Listen Now"-style discovery: a hero rediscover card, cover-forward
/// shelves, and Swift Charts for the library breakdown — instead of stacked
/// grey text cards.
///
/// Built on `List` used as a (correctly width-clamped, lazily-loaded) vertical
/// feed of self-styled cards — each row strips the default List chrome via
/// `.plainCardRow()` so the cards read exactly as before, just hosted in a
/// container that doesn't fall over to the iOS 26 NavigationStack layout bug a
/// custom ScrollView did. See `GenerateView` for the full story.
@MainActor
public struct DiscoveryView: View {
    public init() {}
    @Environment(RoonClient.self) private var client
    @State private var stats: DatabaseManager.LibraryStats?
    @State private var undiscovered: [DatabaseManager.AlbumResult] = []
    @State private var forgotten: [TrackRecord] = []
    @State private var topTracks: [TrackRecord] = []
    @State private var isLoaded = false

    public var body: some View {
        List {
            ZoneHintBanner().plainCardRow()
            weeklyInstap.plainCardRow()
            if let stats {
                if let hero = heroItem { heroCard(hero).plainCardRow() }
                summaryCards(stats).plainCardRow()
                if !undiscovered.isEmpty {
                    shelf("Onontdekte albums", "sparkles",
                          covers: undiscovered.map(albumCover)) {
                        Button { Task { undiscovered = await client.undiscoveredAlbums() } } label: {
                            Image(systemName: "shuffle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Toon een andere selectie")
                    }
                    .plainCardRow()
                }
                if !topTracks.isEmpty {
                    shelf("Jouw toptracks", "star.fill",
                          covers: topTracks.map(trackCover)) {
                        playAllButton(topTracks)
                    }
                    .plainCardRow()
                }
                if forgotten.count > 1 {
                    shelf("Vergeten favorieten", "clock.arrow.circlepath",
                          covers: forgotten.dropFirst().map(trackCover)) {
                        playAllButton(Array(forgotten))
                    }
                    .plainCardRow()
                }
                if !stats.tracksByDecade.isEmpty { decadeCard(stats).plainCardRow() }
                if !stats.topGenres.isEmpty { genreCard(stats).plainCardRow() }
            } else if !isLoaded {
                loadingState.plainCardRow()
            } else {
                emptyState.plainCardRow()
            }
        }
        .navigationTitle("Ontdek")
        .toolbar {
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Ververs")
        }
        .task(id: client.trackCount) { await load() }
    }

    // MARK: - "Ontdek Wekelijks" instap

    /// A prominent entry into the library-first weekly discovery playlist.
    private var weeklyInstap: some View {
        NavigationLink {
            DiscoverWeeklyView()
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(Color.roonGold)
                    .frame(width: 44, height: 44)
                    .background(Color.roonGold.opacity(0.15), in: RoundedRectangle(cornerRadius: Radius.lg))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ontdek Wekelijks").font(.headline)
                    Text("Verse ontdekkingen uit je eigen bibliotheek — elke week vernieuwd.")
                        .font(.caption).foregroundStyle(.secondary)
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

    // MARK: - Hero "rediscover" card

    private struct HeroItem {
        let title: String
        let subtitle: String?
        let imageKey: String?
        let play: () -> Void
        let playLocal: () -> Void
    }

    private var heroItem: HeroItem? {
        if let t = forgotten.first {
            return HeroItem(title: t.title, subtitle: t.artist, imageKey: t.imageKey) {
                play { await client.curateTracks([t], zoneID: $0) }
            } playLocal: {
                Haptics.tap(); Task { await client.playLocally([t]) }
            }
        }
        if let a = undiscovered.first {
            return HeroItem(title: a.album, subtitle: a.artist, imageKey: a.imageKey) {
                play { await client.playAlbum(albumKey: a.albumKey, zoneID: $0) }
            } playLocal: {
                Haptics.tap(); Task { await client.playAlbumLocally(albumKey: a.albumKey) }
            }
        }
        return nil
    }

    private func heroCard(_ item: HeroItem) -> some View {
        HStack(spacing: Spacing.lg) {
            AlbumArtView(imageKey: item.imageKey, size: 120)
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                .shadow(color: .roonShadow, radius: 10, y: 6)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label("Herontdek", systemImage: "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(Color.roonGold)
                Text(item.title).font(.title2.bold()).lineLimit(2)
                if let sub = item.subtitle {
                    Text(sub).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: Spacing.sm)
                HStack(spacing: Spacing.sm) {
                    Button {
                        Haptics.tap()
                        item.play()
                    } label: { Label("Speel nu", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(client.selectedZone == nil)
                    Button { item.playLocal() } label: { Image(systemName: "iphone") }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Speel op dit apparaat")
                        .help("Speel lokaal af op dit apparaat")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .background(
            LinearGradient(colors: [Color.roonGold.opacity(0.18), Color.roonGold.opacity(0.03)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    // MARK: - Cover shelves

    private struct Cover: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let imageKey: String?
        let play: () -> Void
        let playLocal: () -> Void
    }

    private func albumCover(_ a: DatabaseManager.AlbumResult) -> Cover {
        Cover(id: a.albumKey, title: a.album, subtitle: a.artist, imageKey: a.imageKey) {
            play { await client.playAlbum(albumKey: a.albumKey, zoneID: $0) }
        } playLocal: {
            Haptics.tap(); Task { await client.playAlbumLocally(albumKey: a.albumKey) }
        }
    }

    private func trackCover(_ t: TrackRecord) -> Cover {
        Cover(id: t.id, title: t.title, subtitle: t.artist, imageKey: t.imageKey) {
            play { await client.curateTracks([t], zoneID: $0) }
        } playLocal: {
            Haptics.tap(); Task { await client.playLocally([t]) }
        }
    }

    @ViewBuilder
    private func shelf<Trailing: View>(
        _ title: String, _ icon: String, covers: [Cover],
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader(title, icon, trailing: trailing)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.md) {
                    ForEach(covers) { coverTile($0) }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func coverTile(_ c: Cover) -> some View {
        Button {
            Haptics.tap()
            c.play()
        } label: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                AlbumArtView(imageKey: c.imageKey, size: 130)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                    .shadow(color: .roonShadow, radius: 4, y: 2)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, Color.roonGold)
                            .shadow(radius: 3)
                            .padding(6)
                    }
                Text(c.title).font(.caption.weight(.medium)).lineLimit(1)
                if let sub = c.subtitle {
                    Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 130)
        }
        .buttonStyle(.plain)
        .disabled(client.selectedZone == nil)
        .accessibilityLabel("Speel \(c.title)\(c.subtitle.map { " van \($0)" } ?? "")")
        .contextMenu {
            Button("Speel nu", systemImage: "play.fill") { Haptics.tap(); c.play() }
                .disabled(client.selectedZone == nil)
            Button("Speel op dit apparaat", systemImage: "iphone") { c.playLocal() }
        }
    }

    private func playAllButton(_ tracks: [TrackRecord]) -> some View {
        HStack(spacing: Spacing.sm) {
            Button {
                Haptics.tap()
                play { await client.curateTracks(tracks, zoneID: $0) }
            } label: { Label("Speel alles", systemImage: "play.fill") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(client.selectedZone == nil)
            LocalPlayButton { tracks }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func sectionHeader<Trailing: View>(
        _ title: String, _ icon: String, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Label {
                Text(title).font(.headline).lineLimit(1)
            } icon: {
                Image(systemName: icon).foregroundStyle(Color.roonGold)
            }
            Spacer(minLength: Spacing.sm)
            trailing()
        }
    }

    private func play(_ action: @escaping (String) async -> Void) {
        guard let zone = client.selectedZone else { return }
        Task { await action(zone.id) }
    }

    // MARK: - Summary cards

    @ViewBuilder
    func summaryCards(_ stats: DatabaseManager.LibraryStats) -> some View {
        HStack(spacing: Spacing.md) {
            StatCard(label: "Tracks",   value: stats.totalTracks.formatted())
            StatCard(label: "Artiesten", value: stats.totalArtists.formatted())
            StatCard(label: "Albums",   value: stats.totalAlbums.formatted())
        }
    }

    // MARK: - Decade distribution (Swift Charts area)

    @ViewBuilder
    func decadeCard(_ stats: DatabaseManager.LibraryStats) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("Tracks per decennium", "chart.xyaxis.line") { EmptyView() }

            Chart(stats.tracksByDecade, id: \.decade) { item in
                AreaMark(
                    x: .value("Decennium", item.decade),
                    y: .value("Tracks", item.count)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.linearGradient(
                    Gradient(colors: [Color.roonGold.opacity(0.55), Color.roonGold.opacity(0.04)]),
                    startPoint: .top, endPoint: .bottom))

                LineMark(
                    x: .value("Decennium", item.decade),
                    y: .value("Tracks", item.count)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Color.roonGold)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 160)

            // Tap a decade to play a shuffled mix from it.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(stats.tracksByDecade, id: \.decade) { item in
                        if let start = Int(item.decade.dropLast()) {
                            Button(item.decade) {
                                Haptics.tap()
                                var opts = DatabaseManager.FilterOptions()
                                opts.decades = [start]
                                play { await client.playShuffledMix(options: opts, count: 25, zoneID: $0) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(client.selectedZone == nil)
                        }
                    }
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Genre breakdown (Swift Charts bars)

    @ViewBuilder
    func genreCard(_ stats: DatabaseManager.LibraryStats) -> some View {
        let genres = Array(stats.topGenres.prefix(12))
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("Topgenres", "guitars.fill") { EmptyView() }

            Chart(genres, id: \.genre) { item in
                BarMark(
                    x: .value("Tracks", item.count),
                    y: .value("Genre", item.genre)
                )
                .foregroundStyle(Color.roonGold.gradient)
                .cornerRadius(Radius.sm)
            }
            .chartXAxis { AxisMarks(position: .bottom) }
            .frame(height: CGFloat(genres.count) * 26 + 20)

            // Tap a genre to play a shuffled mix from it.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(genres, id: \.genre) { item in
                        Button(item.genre) {
                            Haptics.tap()
                            var opts = DatabaseManager.FilterOptions()
                            opts.genres = [item.genre]
                            play { await client.playShuffledMix(options: opts, count: 25, zoneID: $0) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(client.selectedZone == nil)
                    }
                }
            }
        }
        .cardStyle()
    }

    // MARK: - States

    var loadingState: some View {
        SkeletonRows(count: 8)
    }

    var emptyState: some View {
        ContentUnavailableView(
            "Geen bibliotheekdata",
            systemImage: "music.note.list",
            description: Text("Synchroniseer je bibliotheek in Instellingen om hier statistieken te zien.")
        )
    }

    // MARK: - Data loading

    private func load() async {
        stats = await client.libraryStats()
        async let u = client.undiscoveredAlbums()
        async let f = client.forgottenFavorites()
        async let t = client.topTracks()
        (undiscovered, forgotten, topTracks) = await (u, f, t)
        isLoaded = true
    }
}

// MARK: - Stat card

private struct StatCard: View {
    let label: String
    let value: String

    public var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold().monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
    }
}
