import SwiftUI
import RoonSageCore

@MainActor
struct DiscoveryView: View {
    @Environment(RoonClient.self) private var client
    @State private var stats: DatabaseManager.LibraryStats?
    @State private var isLoaded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let stats {
                    summaryCards(stats)
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
                            .fill(Color.accentColor.opacity(0.7))
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
                            .fill(Color.accentColor.opacity(0.65))
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
        isLoaded = true
    }
}

// MARK: - Stat card

private struct StatCard: View {
    let label: String
    let value: String

    var body: some View {
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
