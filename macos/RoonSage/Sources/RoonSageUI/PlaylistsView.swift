import SwiftUI
import RoonSageCore

/// Saved local playlists — list, expand to view tracks, play to the selected
/// zone, or delete. Playlists are created via curation (save_playlist in the
/// MCP flow) and persist across library re-syncs.
@MainActor
public struct PlaylistsView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    @State private var playlists: [DatabaseManager.PlaylistSummary] = []
    @State private var expanded: Int64? = nil
    @State private var tracks: [TrackRecord] = []
    @State private var qobuzStatus: String? = nil

    public var body: some View {
        Group {
            if playlists.isEmpty {
                ContentUnavailableView(
                    "No saved playlists",
                    systemImage: "list.star",
                    description: Text("Curate tracks and save them (save_playlist via Claude Desktop). They'll appear here and survive a re-sync.")
                )
            } else {
                List {
                    ForEach(playlists, id: \.id) { pl in
                        Section {
                            row(pl)
                            if expanded == pl.id {
                                ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                                    HStack(spacing: 8) {
                                        Text("\(i + 1).")
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 30, alignment: .trailing)
                                        AlbumArtView(imageKey: t.imageKey, size: 32)
                                        Text(t.title)
                                        if let a = t.artist {
                                            Text("— \(a)").foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .onAppear(perform: reload)
        .safeAreaInset(edge: .bottom) {
            if let qobuzStatus {
                Text(qobuzStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }

    @ViewBuilder
    private func row(_ pl: DatabaseManager.PlaylistSummary) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pl.name).font(.headline)
                Text("\(pl.trackCount) tracks · \(pl.createdAt.prefix(10))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await play(pl) } } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(client.selectedZone == nil)
            .help(client.selectedZone == nil ? "Select a zone first" : "Play to \(client.selectedZone?.displayName ?? "")")

            if client.qobuzConfigured {
                Button { saveToQobuz(pl) } label: { Image(systemName: "cloud") }
                    .buttonStyle(.borderless)
                    .help("Save to Qobuz")
            }

            Button { toggle(pl) } label: {
                Image(systemName: expanded == pl.id ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) { delete(pl) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func saveToQobuz(_ pl: DatabaseManager.PlaylistSummary) {
        Task {
            let tracks = await client.playlistTracks(id: pl.id)
            guard !tracks.isEmpty else { return }
            qobuzStatus = "Saving “\(pl.name)” to Qobuz…"
            if let r = await client.saveToQobuz(name: pl.name, tracks: tracks) {
                qobuzStatus = "“\(pl.name)” → Qobuz: \(r.matched)/\(r.total) matched."
            } else {
                qobuzStatus = "Qobuz save failed — check your account in Settings."
            }
        }
    }

    private func reload() {
        playlists = client.playlists()
    }

    private func toggle(_ pl: DatabaseManager.PlaylistSummary) {
        if expanded == pl.id {
            expanded = nil
        } else {
            expanded = pl.id
            Task { tracks = await client.playlistTracksForDisplay(id: pl.id) }
        }
    }

    private func play(_ pl: DatabaseManager.PlaylistSummary) async {
        guard let zone = client.selectedZone else { return }
        _ = await client.playPlaylist(id: pl.id, zoneID: zone.id)
    }

    private func delete(_ pl: DatabaseManager.PlaylistSummary) {
        client.deletePlaylist(id: pl.id)
        if expanded == pl.id { expanded = nil }
        reload()
    }
}
