import RoonSageCore
import SwiftUI

// MARK: - Album detail (drill-down from the album grid)

@MainActor
struct AlbumDetailView: View {
    @Environment(RoonClient.self) private var client
    let album: DatabaseManager.AlbumResult
    @State private var tracks: [DatabaseManager.LibraryTrackRow] = []
    @State private var isLoading = true

    var body: some View {
        List {
            Section {
                header
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: Spacing.md, leading: Spacing.lg,
                                              bottom: Spacing.md, trailing: Spacing.lg))
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            } else {
                ForEach(tracks) { track in
                    LibraryTrackRow(track: track, canPlay: client.selectedZone != nil) {
                        play([track])
                    }
                    .contextMenu {
                        Button("Speel nu") { play([track]) }.disabled(client.selectedZone == nil)
                        Button("Zet in wachtrij") { queue([track]) }.disabled(client.selectedZone == nil)
                    }
                }
            }
        }
        .navigationTitle(album.album)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: album.albumKey) {
            isLoading = true
            tracks = await client.tracksForAlbum(album.albumKey)
            isLoading = false
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            AlbumArtView(imageKey: album.imageKey, size: 120, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 6) {
                Text(album.album).font(.title3.bold()).lineLimit(2)
                if let a = album.artist { Text(a).font(.callout).foregroundStyle(.secondary) }
                Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                HStack(spacing: Spacing.sm) {
                    Button { play(tracks) } label: { Label("Speel", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(Color.roonGold)
                    Button { queue(tracks) } label: { Label("Wachtrij", systemImage: "text.append") }
                        .buttonStyle(.bordered)
                }
                .disabled(client.selectedZone == nil || tracks.isEmpty)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let y = album.year { parts.append(String(y)) }
        parts.append("\(album.trackCount) tracks")
        return parts.joined(separator: " · ")
    }

    private func record(_ t: DatabaseManager.LibraryTrackRow) -> TrackRecord {
        TrackRecord(id: t.id, title: t.title, artist: t.artist, album: t.album, year: t.year, isLive: t.isLive)
    }

    private func play(_ rows: [DatabaseManager.LibraryTrackRow]) {
        guard let zone = client.selectedZone, !rows.isEmpty else { return }
        Haptics.tap()
        Task { await client.curateTracks(rows.map(record), zoneID: zone.id) }
    }

    private func queue(_ rows: [DatabaseManager.LibraryTrackRow]) {
        guard let zone = client.selectedZone, !rows.isEmpty else { return }
        Haptics.tap()
        Task { await client.queueTracks(rows.map(record), zoneID: zone.id) }
    }
}

// MARK: - Artist detail (drill-down from the artist grid)

@MainActor
struct ArtistDetailView: View {
    @Environment(RoonClient.self) private var client
    let artist: DatabaseManager.ArtistResult
    @State private var albums: [DatabaseManager.AlbumResult] = []
    @State private var isLoading = true

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.lg)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name).font(.title2.bold())
                        Text("\(artist.albumCount) albums · \(artist.trackCount) tracks")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { playArtist() } label: { Label("Speel alles", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(Color.roonGold)
                        .disabled(client.selectedZone == nil)
                }

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                } else {
                    LazyVGrid(columns: columns, spacing: Spacing.lg) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) { AlbumGridCell(album: album) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Speel album") { playAlbum(album) }
                                        .disabled(client.selectedZone == nil)
                                }
                        }
                    }
                }
            }
            .padding(Spacing.lg)
        }
        .navigationTitle(artist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: artist.name) {
            isLoading = true
            albums = await client.albumsByArtist(artist.name)
            isLoading = false
        }
    }

    private func playArtist() {
        guard let zone = client.selectedZone else { return }
        Haptics.tap()
        Task { await client.playArtist(name: artist.name, zoneID: zone.id) }
    }

    private func playAlbum(_ album: DatabaseManager.AlbumResult) {
        guard let zone = client.selectedZone else { return }
        Haptics.tap()
        Task { await client.playAlbum(albumKey: album.albumKey, zoneID: zone.id) }
    }
}
