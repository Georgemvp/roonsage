import RoonSageCore
import SwiftUI

@MainActor
struct LibraryView: View {
    @Environment(RoonClient.self) private var client
    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var tracks: [DatabaseManager.LibraryTrackRow] = []
    @State private var tags: [(tag: String, count: Int)] = []

    var body: some View {
        VStack(spacing: 0) {
            if client.isSyncing { SyncProgressBanner() }

            if !tags.isEmpty { tagChips }

            if tracks.isEmpty && !client.isSyncing {
                emptyState
            } else {
                List(tracks) { track in
                    LibraryTrackRow(track: track, canPlay: client.selectedZone != nil) {
                        if let zone = client.selectedZone {
                            Task { await client.playTrack(id: track.id, title: track.title, artist: track.artist, zoneID: zone.id) }
                        }
                    }
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
                    Button { client.startSync() } label: {
                        Label("Sync Library", systemImage: "arrow.clockwise")
                    }
                    .disabled(!client.connectionState.isConnected)
                }
            }
        }
        .onChange(of: searchText) { _, _ in reloadTracks() }
        .onChange(of: selectedTag) { _, _ in reloadTracks() }
        .onChange(of: client.trackCount) { _, _ in reload() }
        .onAppear { reload() }
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
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(isOn ? Color.accentColor : Color(.quaternaryLabelColor).opacity(0.5),
                                        in: Capsule())
                            .foregroundStyle(isOn ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func reload() {
        tags = client.topTags(limit: 28)
        reloadTracks()
    }

    private func reloadTracks() {
        tracks = client.browseTracks(query: searchText, tag: selectedTag)
    }

    @ViewBuilder
    var emptyState: some View {
        if client.connectionState.isConnected {
            ContentUnavailableView("No matching tracks", systemImage: "music.note.list",
                description: Text(selectedTag != nil ? "No tracks tagged “\(selectedTag!)”." : "Sync your library, then search."))
        } else {
            ContentUnavailableView("Not connected", systemImage: "wifi.slash",
                description: Text("Connect to your Roon Core first."))
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
                ProgressView(value: progress.fraction).progressViewStyle(.linear)
                Text("\(progress.albumsCompleted)/\(progress.albumsTotal)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }
            Text(progress.phase).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.regularMaterial)
    }
}

// MARK: - Track row (with audio features)

struct LibraryTrackRow: View {
    let track: DatabaseManager.LibraryTrackRow
    let canPlay: Bool
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(track.title).font(.body).lineLimit(1)
                    if track.isLive {
                        Text("LIVE").font(.caption2.bold()).foregroundStyle(.orange)
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
            Spacer()
            Button(action: onPlay) { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .disabled(!canPlay)
                .help(canPlay ? "Play now" : "Select a zone first")
        }
        .padding(.vertical, 2)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }
}
