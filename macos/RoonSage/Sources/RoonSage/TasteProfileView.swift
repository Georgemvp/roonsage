import SwiftUI
import RoonSageCore

@MainActor
struct TasteProfileView: View {
    @Environment(RoonClient.self) private var client
    @State private var topArtists: [(artist: String, count: Int)] = []
    @State private var recentListens: [DatabaseManager.ListenEntry] = []
    @State private var totalListens: Int = 0
    @State private var isLoaded = false
    @State private var selectedTab: Tab = .topArtists

    enum Tab: String, CaseIterable {
        case topArtists = "Top Artists"
        case recent     = "Recent Plays"
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoaded && totalListens == 0 {
                emptyState
            } else {
                headerStats
                Divider()
                tabPicker
                Divider()
                tabContent
            }
        }
        .navigationTitle("Taste Profile")
        .onAppear { load() }
        .onChange(of: client.zones) { _, _ in load() }
    }

    // MARK: - Header

    var headerStats: some View {
        HStack(spacing: 24) {
            VStack(spacing: 2) {
                Text("\(totalListens.formatted())")
                    .font(.title2.bold().monospacedDigit())
                Text("Total plays")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 32)
            VStack(spacing: 2) {
                Text("\(topArtists.count.formatted())")
                    .font(.title2.bold().monospacedDigit())
                Text("Artists heard")
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Tab content

    @ViewBuilder
    var tabContent: some View {
        switch selectedTab {
        case .topArtists: artistsList
        case .recent:     recentList
        }
    }

    var artistsList: some View {
        List {
            ForEach(Array(topArtists.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, alignment: .trailing)

                    Text(item.artist)
                        .font(.body)
                        .lineLimit(1)

                    Spacer()

                    Text("\(item.count) play\(item.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.plain)
    }

    var recentList: some View {
        List(Array(recentListens.enumerated()), id: \.offset) { _, entry in
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
                HStack(spacing: 4) {
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
        .listStyle(.plain)
    }

    // MARK: - Empty state

    var emptyState: some View {
        ContentUnavailableView(
            "No listening history yet",
            systemImage: "chart.bar",
            description: Text("Play music through Roon and your taste profile will build up here automatically.")
        )
    }

    // MARK: - Helpers

    private func load() {
        totalListens   = client.totalListens()
        topArtists     = client.topArtistsListened(limit: 50)
        recentListens  = client.recentListens(limit: 100)
        isLoaded = true
    }

    private func formatDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }
}
