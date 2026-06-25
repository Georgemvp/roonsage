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
    @State private var statusBanner: String? = nil
    /// nil = in progress (spinner), true = success (green), false = failure (red).
    @State private var statusOK: Bool? = nil
    @State private var hasLoaded = false
    @State private var pendingDelete: DatabaseManager.PlaylistSummary? = nil
    @Environment(\.navigateTo) private var navigateTo

    public var body: some View {
        Group {
            if !hasLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if playlists.isEmpty {
                ContentUnavailableView {
                    Label("Geen bewaarde playlists", systemImage: "list.star")
                } description: {
                    Text("Stel tracks samen en bewaar ze als playlist — ze verschijnen hier en blijven staan na een hersynchronisatie.")
                } actions: {
                    Button {
                        Haptics.tap()
                        navigateTo(.generate)
                    } label: {
                        Label("Genereer een playlist", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(playlists, id: \.id) { pl in
                        Section {
                            row(pl)
                            if expanded == pl.id {
                                ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                                    HStack(spacing: Spacing.sm) {
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
                .accessibilityLabel("Ververs")
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
            if let statusBanner {
                Label {
                    Text(statusBanner)
                } icon: {
                    if let statusOK {
                        Image(systemName: statusOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .font(.caption)
                .foregroundStyle(statusOK == nil ? AnyShapeStyle(.secondary)
                                 : AnyShapeStyle(statusOK! ? Color.roonSuccess : Color.roonDanger))
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.standard, value: statusBanner)
    }

    @ViewBuilder
    private func row(_ pl: DatabaseManager.PlaylistSummary) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pl.name).font(.headline)
                    if pl.source == "listenbrainz" {
                        Text("ListenBrainz")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.roonGold.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.roonGold)
                            .accessibilityLabel("Bron: ListenBrainz")
                    }
                }
                Text("\(pl.trackCount) nummers · \(pl.createdAt.prefix(10))")
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
            statusOK = nil
            statusBanner = "“\(pl.name)” bewaren in Qobuz…"
            if let r = await client.saveToQobuz(name: pl.name, tracks: tracks) {
                statusOK = true
                statusBanner = "“\(pl.name)” → Qobuz: \(r.matched)/\(r.total) gematcht."
                Haptics.success()
            } else {
                statusOK = false
                statusBanner = "Bewaren in Qobuz mislukt — controleer je account in Instellingen."
                Haptics.error()
            }
        }
    }

    private func reload() {
        Task {
            playlists = await client.playlists()
            hasLoaded = true
        }
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
        Haptics.tap()
        statusOK = nil
        statusBanner = "“\(pl.name)” starten…"
        let played = await client.playPlaylist(id: pl.id, zoneID: zone.id)
        if played > 0 {
            statusOK = true
            statusBanner = "“\(pl.name)” speelt af in \(zone.displayName) — \(played) nummers."
            Haptics.success()
        } else {
            statusOK = false
            statusBanner = "“\(pl.name)” kon niet starten — geen van de tracks was beschikbaar."
            Haptics.error()
        }
    }

    private func delete(_ pl: DatabaseManager.PlaylistSummary) {
        client.deletePlaylist(id: pl.id)
        if expanded == pl.id { expanded = nil }
        reload()
    }
}
