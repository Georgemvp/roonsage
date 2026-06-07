import SwiftUI
import RoonSageCore

@MainActor
struct LibraryView: View {
    @Environment(RoonClient.self) private var client
    @State private var searchText = ""
    @State private var tracks: [TrackRecord] = []

    var body: some View {
        VStack(spacing: 0) {
            // Sync banner
            if client.isSyncing {
                SyncProgressBanner()
            }

            // Track list
            if tracks.isEmpty && !client.isSyncing {
                emptyState
            } else {
                List(tracks, id: \.id) { track in
                    TrackRow(track: track)
                }
            }
        }
        .navigationTitle("Library (\(client.trackCount) tracks)")
        .searchable(text: $searchText, prompt: "Search title, artist or album…")
        .toolbar {
            ToolbarItem {
                if client.isSyncing {
                    Button("Cancel", role: .cancel) { client.cancelSync() }
                } else {
                    Button {
                        client.startSync()
                    } label: {
                        Label("Sync Library", systemImage: "arrow.clockwise")
                    }
                    .disabled(!client.connectionState.isConnected)
                }
            }
        }
        .onChange(of: searchText) { _, query in
            tracks = client.searchTracks(query: query)
        }
        .onChange(of: client.trackCount) { _, _ in
            tracks = client.searchTracks(query: searchText)
        }
        .onAppear {
            tracks = client.searchTracks(query: searchText)
        }
    }

    @ViewBuilder
    var emptyState: some View {
        if client.connectionState.isConnected {
            ContentUnavailableView(
                "Library not synced",
                systemImage: "music.note.list",
                description: Text("Press Sync Library in the toolbar to import your Roon library.")
            )
        } else {
            ContentUnavailableView(
                "Not connected",
                systemImage: "wifi.slash",
                description: Text("Connect to your Roon Core first.")
            )
        }
    }
}

// MARK: - Sync progress banner

@MainActor
struct SyncProgressBanner: View {
    @Environment(RoonClient.self) private var client

    var body: some View {
        let progress = client.syncProgress
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                Text("\(progress.albumsCompleted)/\(progress.albumsTotal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }
            Text(progress.phase)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }
}

// MARK: - Track row

struct TrackRow: View {
    let track: TrackRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                if let year = track.year {
                    Text(String(year))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if track.isLive {
                    Text("LIVE")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 4) {
                if let artist = track.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if track.artist != nil, track.album != nil {
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                }
                if let album = track.album {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
