import SwiftUI
import RoonSageCore

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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let stats {
                    summaryCards(stats)
                    if !stats.tracksByDecade.isEmpty { decadePicksSection(stats) }
                    if !stats.topGenres.isEmpty { genreExplorerSection(stats) }
                    if !undiscovered.isEmpty { undiscoveredSection }
                    if !topTracks.isEmpty { topTracksSection }
                    if !forgotten.isEmpty { forgottenSection }
                    genreSection(stats)
                    if !stats.tracksByDecade.isEmpty {
                        decadeSection(stats)
                    }
                } else if !isLoaded {
                    loadingState
                } else {
                    emptyState
                }
            }
            .padding(20)
        }
        .navigationTitle("Discovery")
        .onAppear { load() }
        .onChange(of: client.trackCount) { _, _ in load() }
    }

    // MARK: - Undiscovered albums (never played)

    @ViewBuilder
    var undiscoveredSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Undiscovered Albums").font(.headline)
                Spacer()
                Button { Task { undiscovered = await client.undiscoveredAlbums() } } label: {
                    Image(systemName: "shuffle")
                }
                .buttonStyle(.borderless)
                .help("Show a different selection")
            }
            ForEach(undiscovered, id: \.albumKey) { album in
                HStack(spacing: 10) {
                    AlbumArtView(imageKey: album.imageKey, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.album).font(.callout).lineLimit(1)
                        Text("\(album.artist ?? "Unknown")\(album.year.map { " · \($0)" } ?? "") · \(album.trackCount) tracks")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { play { await client.playAlbum(albumKey: album.albumKey, zoneID: $0) } } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(client.selectedZone == nil)
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Forgotten favorites

    @ViewBuilder
    var forgottenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Forgotten Favorites").font(.headline)
                Spacer()
                Button { play { await client.curateTracks(forgotten, zoneID: $0) } } label: {
                    Label("Play all", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(client.selectedZone == nil)
            }
            ForEach(Array(forgotten.enumerated()), id: \.offset) { _, t in
                HStack(spacing: 8) {
                    Text(t.title).font(.callout).lineLimit(1)
                    if let a = t.artist {
                        Text("— \(a)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Decade picks

    @ViewBuilder
    func decadePicksSection(_ stats: DatabaseManager.LibraryStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Decade Picks").font(.headline)
            Text("Play a random mix from a decade").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                ForEach(stats.tracksByDecade, id: \.decade) { item in
                    if let start = Int(item.decade.dropLast()) {
                        Button(item.decade) {
                            var opts = DatabaseManager.FilterOptions()
                            opts.decades = [start]
                            play { await client.playShuffledMix(options: opts, count: 25, zoneID: $0) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(client.selectedZone == nil)
                    }
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Genre explorer

    @ViewBuilder
    func genreExplorerSection(_ stats: DatabaseManager.LibraryStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Genre Explorer").font(.headline)
            Text("Play a random mix from a genre").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                ForEach(stats.topGenres.prefix(12), id: \.genre) { item in
                    Button {
                        var opts = DatabaseManager.FilterOptions()
                        opts.genres = [item.genre]
                        play { await client.playShuffledMix(options: opts, count: 25, zoneID: $0) }
                    } label: {
                        Text(item.genre).lineLimit(1).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(client.selectedZone == nil)
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Top tracks

    @ViewBuilder
    var topTracksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your Top Tracks").font(.headline)
                Spacer()
                Button { play { await client.curateTracks(topTracks, zoneID: $0) } } label: {
                    Label("Play all", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(client.selectedZone == nil)
            }
            ForEach(Array(topTracks.enumerated()), id: \.offset) { i, t in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary).frame(width: 24, alignment: .trailing)
                    Text(t.title).font(.callout).lineLimit(1)
                    if let a = t.artist {
                        Text("— \(a)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func play(_ action: @escaping (String) async -> Void) {
        guard let zone = client.selectedZone else { return }
        Task { await action(zone.id) }
    }

    // MARK: - Summary cards

    @ViewBuilder
    func summaryCards(_ stats: DatabaseManager.LibraryStats) -> some View {
        HStack(spacing: 12) {
            StatCard(label: "Tracks",  value: stats.totalTracks.formatted())
            StatCard(label: "Artists", value: stats.totalArtists.formatted())
            StatCard(label: "Albums",  value: stats.totalAlbums.formatted())
        }
    }

    // MARK: - Genre breakdown

    @ViewBuilder
    func genreSection(_ stats: DatabaseManager.LibraryStats) -> some View {
        let genres = stats.topGenres
        let maxCount = genres.first?.count ?? 1

        VStack(alignment: .leading, spacing: 10) {
            Text("Top Genres")
                .font(.headline)

            ForEach(genres.prefix(15), id: \.genre) { item in
                HStack(spacing: 8) {
                    Text(item.genre)
                        .font(.callout)
                        .frame(width: 150, alignment: .leading)
                        .lineLimit(1)

                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.roonGold.opacity(0.7))
                            .frame(width: geo.size.width * CGFloat(item.count) / CGFloat(maxCount))
                    }
                    .frame(height: 14)

                    Text("\(item.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Decade distribution

    @ViewBuilder
    func decadeSection(_ stats: DatabaseManager.LibraryStats) -> some View {
        let decades = stats.tracksByDecade
        let maxCount = decades.map(\.count).max() ?? 1

        VStack(alignment: .leading, spacing: 10) {
            Text("Tracks by Decade")
                .font(.headline)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(decades, id: \.decade) { item in
                    VStack(spacing: 4) {
                        Text("\(item.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.roonGold.opacity(0.65))
                            .frame(
                                width: 36,
                                height: max(4, 100 * CGFloat(item.count) / CGFloat(maxCount))
                            )

                        Text(item.decade)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - States

    var loadingState: some View {
        ContentUnavailableView("Loading…", systemImage: "ellipsis")
    }

    var emptyState: some View {
        ContentUnavailableView(
            "No library data",
            systemImage: "music.note.list",
            description: Text("Sync your library in Settings to see stats here.")
        )
    }

    // MARK: - Data loading

    private func load() {
        stats = client.libraryStats()
        Task {
            undiscovered = await client.undiscoveredAlbums()
            forgotten = await client.forgottenFavorites()
            topTracks = await client.topTracks()
            isLoaded = true
        }
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
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
