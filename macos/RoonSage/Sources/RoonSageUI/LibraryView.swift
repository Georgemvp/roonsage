import RoonSageCore
import SwiftUI

@MainActor
public struct LibraryView: View {
    public init() {}
    @Environment(RoonClient.self) private var client
    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var tracks: [DatabaseManager.LibraryTrackRow] = []
    @State private var tags: [(tag: String, count: Int)] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var sort: SortField = .title
    @State private var selection = Set<String>()
    @State private var showSaveSheet = false
    @State private var newPlaylistName = ""

    enum SortField: String, CaseIterable, Identifiable {
        case title = "Title", artist = "Artist", year = "Year", bpm = "BPM"
        var id: String { rawValue }
    }

    private var sortedTracks: [DatabaseManager.LibraryTrackRow] {
        switch sort {
        case .title:  return tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: return tracks.sorted { ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending }
        case .year:   return tracks.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
        case .bpm:    return tracks.sorted { ($0.bpm ?? 0) < ($1.bpm ?? 0) }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if client.isSyncing { SyncProgressBanner() }

            if !tags.isEmpty { tagChips }

            if tracks.isEmpty && !client.isSyncing {
                emptyState
            } else {
                List(sortedTracks, selection: $selection) { track in
                    LibraryTrackRow(track: track, canPlay: client.selectedZone != nil) {
                        play([asRecord(track)])
                    }
                    .contextMenu { rowMenu(track) }
                    .tag(track.id)
                }
                if !selection.isEmpty { selectionBar }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selection.isEmpty)
        .navigationTitle("Library (\(client.trackCount) tracks)")
        .searchable(text: $searchText, prompt: "Search title, artist or album…")
        .toolbar {
            ToolbarItem {
                Picker("Sort", selection: $sort) {
                    ForEach(SortField.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Sort tracks")
            }
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
        .onChange(of: searchText) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !Task.isCancelled { reloadTracks() }
            }
        }
        .onChange(of: selectedTag) { _, _ in reloadTracks() }
        .onChange(of: client.trackCount) { _, _ in reload() }
        .onAppear { reload() }
        .alert("Save as playlist", isPresented: $showSaveSheet) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                _ = client.savePlaylist(name: name, tracks: selectedRecords())
                newPlaylistName = ""
                selection.removeAll()
            }
        } message: {
            Text("Save \(selection.count) selected track\(selection.count == 1 ? "" : "s") as a local playlist.")
        }
    }

    // MARK: - Selection action bar

    private var selectionBar: some View {
        HStack(spacing: Spacing.md) {
            Text("\(selection.count) selected").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button { play(selectedRecords()) } label: { Label("Play", systemImage: "play.fill") }
                .disabled(client.selectedZone == nil)
            Button { queue(selectedRecords()) } label: { Label("Queue", systemImage: "text.append") }
                .disabled(client.selectedZone == nil)
            Button { showSaveSheet = true } label: { Label("Save", systemImage: "plus.rectangle.on.folder") }
            Button { selection.removeAll() } label: { Label("Clear", systemImage: "xmark") }
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
        Button("Play Now") { play([rec]) }.disabled(!hasZone)
        Button("Play Next") { queue([rec], next: true) }.disabled(!hasZone)
        Button("Add to Queue") { queue([rec]) }.disabled(!hasZone)
        Divider()
        Button("Start Sonic Radio") {
            guard let zone = client.selectedZone else { return }
            Task { await client.playSonicRadio(title: track.title, artist: track.artist, album: track.album, zoneID: zone.id) }
        }.disabled(!hasZone)
        Divider()
        Button("Save as Playlist…") {
            selection = [track.id]
            showSaveSheet = true
        }
    }

    // MARK: - Helpers

    private func asRecord(_ t: DatabaseManager.LibraryTrackRow) -> TrackRecord {
        TrackRecord(id: t.id, title: t.title, artist: t.artist, album: t.album, year: t.year, isLive: t.isLive)
    }

    private func selectedRecords() -> [TrackRecord] {
        sortedTracks.filter { selection.contains($0.id) }.map(asRecord)
    }

    private func play(_ tracks: [TrackRecord]) {
        guard let zone = client.selectedZone, !tracks.isEmpty else { return }
        Task { await client.curateTracks(tracks, zoneID: zone.id) }
    }

    private func queue(_ tracks: [TrackRecord], next: Bool = false) {
        guard let zone = client.selectedZone, !tracks.isEmpty else { return }
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
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(isOn ? Color.roonGold : Color.platformQuaternaryFill.opacity(0.5),
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
        .padding(.horizontal, 16).padding(.vertical, 8)
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
