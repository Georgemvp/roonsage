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
    @State private var pendingDelete: DatabaseManager.PlaylistSummary? = nil

    public var body: some View {
        Group {
            if playlists.isEmpty {
                ContentUnavailableView(
                    "Geen bewaarde playlists",
                    systemImage: "list.star",
                    description: Text("Stel tracks samen en bewaar ze als playlist — ze verschijnen hier en blijven staan na een hersynchronisatie.")
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
        .toolbar {
            Button(action: reload) { Image(systemName: "arrow.clockwise") }
                .help("Ververs")
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "Playlist verwijderen?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Verwijder", role: .destructive) {
                if let pl = pendingDelete { delete(pl) }
                pendingDelete = nil
            }
            Button("Annuleer", role: .cancel) { pendingDelete = nil }
        } message: {
            if let name = pendingDelete?.name {
                Text("\(name) wordt definitief verwijderd.")
            }
        }
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
            .accessibilityLabel("Speel playlist")
            .help(client.selectedZone == nil ? "Kies eerst een zone" : "Speel af in \(client.selectedZone?.displayName ?? "")")

            if client.qobuzConfigured {
                Button { saveToQobuz(pl) } label: { Image(systemName: "cloud") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Bewaar in Qobuz")
                    .help("Bewaar in Qobuz")
            }

            Button { toggle(pl) } label: {
                Image(systemName: expanded == pl.id ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(expanded == pl.id ? "Verberg tracks" : "Toon tracks")

            Button(role: .destructive) { pendingDelete = pl } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Verwijder playlist")
        }
    }

    private func saveToQobuz(_ pl: DatabaseManager.PlaylistSummary) {
        Task {
            let tracks = await client.playlistTracks(id: pl.id)
            guard !tracks.isEmpty else { return }
            qobuzStatus = "“\(pl.name)” bewaren in Qobuz…"
            if let r = await client.saveToQobuz(name: pl.name, tracks: tracks) {
                qobuzStatus = "“\(pl.name)” → Qobuz: \(r.matched)/\(r.total) gematcht."
            } else {
                qobuzStatus = "Bewaren in Qobuz mislukt — controleer je account in Instellingen."
            }
        }
    }

    private func reload() {
        Task { playlists = await client.playlists() }
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
