import RoonSageCore
import SwiftUI

/// Song Alchemy: sonic vector mixing.
/// ADD tracks that define the vibe; SUBTRACT tracks that represent what to avoid.
/// Result = mean(add_features) − 0.5 × mean(subtract_features).
@MainActor
public struct SongAlchemyView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    @State private var addTracks: [DatabaseManager.SonicTrack] = []
    @State private var subtractTracks: [DatabaseManager.SonicTrack] = []
    @State private var results: [SonicEngine.Scored] = []
    @State private var searchQuery = ""
    @State private var searchResults: [DatabaseManager.SonicTrack] = []
    @State private var addingTo: Bucket = .add
    @State private var loading = false
    @State private var noResult = false

    enum Bucket { case add, subtract }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header

                ZoneHintBanner()

                HStack(alignment: .top, spacing: Spacing.md) {
                    bucket(title: "Optellen", tracks: $addTracks, tint: Color.roonSuccess,
                           icon: "plus.circle.fill", bucket: .add)
                    bucket(title: "Aftrekken", tracks: $subtractTracks, tint: Color.roonDanger,
                           icon: "minus.circle.fill", bucket: .subtract)
                }

                searchBar

                if addTracks.isEmpty {
                    Text("Voeg minimaal één track toe aan Optellen.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Button {
                        Haptics.tap()
                        Task { await compute() }
                    } label: {
                        Label(loading ? "Mixen…" : "Mix", systemImage: "wand.and.sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.roonGold)
                    .disabled(loading)
                }

                if noResult && !loading {
                    ContentUnavailableView(
                        "Niets te mixen",
                        systemImage: "wand.and.sparkles",
                        description: Text("Geen passende tracks gevonden. Voeg andere tracks toe, of zorg dat je bibliotheek sonisch geanalyseerd en gesynchroniseerd is."))
                }

                if !results.isEmpty {
                    Divider()
                    resultsList
                }
            }
            .padding()
        }
        .navigationTitle("Song Alchemy")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("Song Alchemy", systemImage: "wand.and.sparkles")
                .font(.title2.bold())
            Text("Meng sonische profielen: optellen = sfeer overnemen, aftrekken = sfeer vermijden.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Bucket column

    private func bucket(title: String, tracks: Binding<[DatabaseManager.SonicTrack]>,
                        tint: Color, icon: String, bucket b: Bucket) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.subheadline.bold())
                Spacer()
                Button {
                    addingTo = b
                    searchQuery = ""
                    searchResults = []
                } label: {
                    Image(systemName: "plus").foregroundStyle(tint)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Track toevoegen aan \(title)")
            }
            if tracks.wrappedValue.isEmpty {
                Text("Leeg")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.md))
            } else {
                ForEach(tracks.wrappedValue, id: \.id) { track in
                    HStack(spacing: Spacing.sm) {
                        AlbumArtView(imageKey: track.imageKey, size: 32)
                            .clipShape(Circle())
                        Text(track.title).font(.caption).lineLimit(1)
                        Spacer()
                        Button {
                            tracks.wrappedValue.removeAll { $0.id == track.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.md))
    }

    // MARK: Search

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Track zoeken om toe te voegen…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { performSearch() }
                    .onChange(of: searchQuery) { _, _ in performSearch() }
                if !searchQuery.isEmpty {
                    Button { searchQuery = ""; searchResults = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(Spacing.md)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.md))

            ForEach(searchResults.prefix(5), id: \.id) { track in
                HStack(spacing: Spacing.sm) {
                    AlbumArtView(imageKey: track.imageKey, size: 36)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.callout).lineLimit(1)
                        if let a = track.artist {
                            Text(a).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("+") {
                        if addingTo == .add {
                            if !addTracks.contains(where: { $0.id == track.id }) {
                                addTracks.append(track)
                            }
                        } else {
                            if !subtractTracks.contains(where: { $0.id == track.id }) {
                                subtractTracks.append(track)
                            }
                        }
                        searchQuery = ""; searchResults = []
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(addingTo == .add ? Color.roonSuccess : Color.roonDanger)
                    .controlSize(.small)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.md))
            }
        }
    }

    // MARK: Results

    private var topRecords: [TrackRecord] {
        results.prefix(20).map {
            TrackRecord(id: $0.track.id, title: $0.track.title,
                        artist: $0.track.artist, album: $0.track.album)
        }
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("Alchemieresultaten (\(results.count))").font(.headline)
                Spacer()
                if let zone = client.selectedZone {
                    Button {
                        Haptics.success()
                        Task { await client.curateTracks(topRecords, zoneID: zone.id) }
                    } label: { Label("Speel top 20", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.roonGold)
                    .controlSize(.small)
                }
                LocalPlayButton { topRecords }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            ForEach(results.prefix(30)) { scored in
                HStack(spacing: Spacing.md) {
                    AlbumArtView(imageKey: scored.track.imageKey, size: 44)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scored.track.title).font(.callout).lineLimit(1)
                        if let a = scored.track.artist {
                            Text(a).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: Spacing.xs) {
                            if let bpm = scored.track.bpm, bpm > 0 {
                                Badge("\(Int(bpm)) BPM")
                            }
                            if !scored.track.camelot.isEmpty {
                                Badge(scored.track.camelot, tint: .roonGold)
                            }
                        }
                    }
                    Spacer()
                    Text("\(Int(scored.similarity * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(scored.similarity > 0.7 ? Color.roonSuccess : .secondary)
                }
                .padding(.vertical, Spacing.xs)
            }
        }
    }

    // MARK: Logic

    private func performSearch() {
        let q = searchQuery
        guard q.count >= 2 else { searchResults = []; return }
        Task {
            let r = await client.sonicSearch(q)
            searchResults = r
        }
    }

    private func compute() async {
        guard !addTracks.isEmpty else { return }
        loading = true
        noResult = false
        defer { loading = false }
        let adds = addTracks
        let subtracts = subtractTracks
        let lib = await client.sonicLibrary()
        let index = await client.sonicVectorIndex()
        let r = await Task.detached {
            SonicEngine.alchemy(add: adds, subtract: subtracts, in: lib, limit: 30, index: index)
        }.value
        withAnimation(Motion.standard) { results = r }
        noResult = r.isEmpty
        if r.isEmpty { Haptics.error() } else { Haptics.success() }
    }
}
