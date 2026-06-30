import RoonSageCore
import SwiftUI

/// Sonic bridge: pick a Start and End track; the engine weaves a path through
/// the library that transitions from one to the other as smoothly as possible.
///
/// Built on `List`/`Section` (not a custom `ScrollView`/`VStack`) — see
/// `GenerateView` for why.
@MainActor
public struct SongPathsView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    @State private var fromQuery = ""
    @State private var toQuery = ""
    @State private var fromTrack: DatabaseManager.SonicTrack?
    @State private var toTrack: DatabaseManager.SonicTrack?
    @State private var path: [SongPaths.Step] = []
    @State private var loading = false
    @State private var stepCount: Double = 10
    @State private var fromResults: [DatabaseManager.SonicTrack] = []
    @State private var toResults: [DatabaseManager.SonicTrack] = []
    @State private var noResult = false

    public var body: some View {
        List {
            Section {
                Text("Vind een soepele sonische brug tussen twee tracks via je bibliotheek.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            ZoneHintBanner().plainCardRow()

            Section("Kies tracks") {
                trackPicker(label: "Van", query: $fromQuery,
                            selected: $fromTrack, results: $fromResults,
                            onSearch: searchFrom)
                trackPicker(label: "Naar", query: $toQuery,
                            selected: $toTrack, results: $toResults,
                            onSearch: searchTo)
            }

            if fromTrack != nil && toTrack != nil {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Brugtracks: \(Int(stepCount) - 2)")
                            .font(.caption).foregroundStyle(.secondary)
                        Slider(value: $stepCount, in: 4...16, step: 1)
                            .tint(Color.roonGold)
                    }

                    Button {
                        Haptics.tap()
                        Task { await buildPath() }
                    } label: {
                        Label(loading ? "Zoeken…" : "Bouw brug",
                              systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Color.roonGold)
                    .disabled(loading)
                    .listRowBackground(Color.clear)
                }
            }

            if noResult && !loading {
                Section {
                    ContentUnavailableView(
                        "Geen brug gevonden",
                        systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                        description: Text("Deze twee tracks liggen sonisch te ver uit elkaar, of er zijn te weinig geanalyseerde tracks. Probeer andere tracks of analyseer meer van je bibliotheek."))
                    .listRowBackground(Color.clear)
                }
                .listRowSeparator(.hidden)
            }

            if !path.isEmpty { pathResultSection }
        }
        .navigationTitle("Song Paths")
    }

    // MARK: Track picker

    private func trackPicker(
        label: String,
        query: Binding<String>,
        selected: Binding<DatabaseManager.SonicTrack?>,
        results: Binding<[DatabaseManager.SonicTrack]>,
        onSearch: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let track = selected.wrappedValue {
                HStack(spacing: Spacing.md) {
                    AlbumArtView(imageKey: track.imageKey, size: 44)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.callout).lineLimit(1)
                        if let a = track.artist {
                            Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("Wijzig") {
                        selected.wrappedValue = nil
                        query.wrappedValue = ""
                        results.wrappedValue = []
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.roonGold)
                }
                .padding(Spacing.md)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.md))
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Zoek track…", text: query)
                        .textFieldStyle(.plain)
                        .onSubmit(onSearch)
                        .onChange(of: query.wrappedValue) { _, _ in onSearch() }
                }
                .padding(Spacing.md)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.md))

                if !results.wrappedValue.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(results.wrappedValue.prefix(5), id: \.id) { track in
                            Button {
                                selected.wrappedValue = track
                                query.wrappedValue = track.title
                                results.wrappedValue = []
                            } label: {
                                HStack(spacing: Spacing.sm) {
                                    AlbumArtView(imageKey: track.imageKey, size: 36)
                                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title).font(.callout).lineLimit(1)
                                        if let a = track.artist {
                                            Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, Spacing.md)
                                .padding(.vertical, Spacing.sm)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.md))
                }
            }
        }
    }

    // MARK: Path result

    private var pathRecords: [TrackRecord] {
        path.map {
            TrackRecord(id: $0.track.id, title: $0.track.title,
                        artist: $0.track.artist, album: $0.track.album)
        }
    }

    private var pathResultSection: some View {
        Section("Sonisch pad (\(path.count) tracks)") {
            HStack(spacing: Spacing.sm) {
                if let zone = client.selectedZone {
                    Button {
                        Haptics.success()
                        Task { await client.curateTracks(pathRecords, zoneID: zone.id) }
                    } label: { Label("Speel pad", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.roonGold)
                }
                LocalPlayButton { pathRecords }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(path.enumerated()), id: \.element.id) { idx, step in
                    HStack(spacing: Spacing.md) {
                        ZStack {
                            Circle()
                                .fill(idx == 0 || idx == path.count - 1
                                      ? Color.roonGold
                                      : Color.secondary.opacity(0.3))
                                .frame(width: 28, height: 28)
                            Text("\(idx + 1)").font(.caption.bold())
                                .foregroundStyle(idx == 0 || idx == path.count - 1 ? .black : .primary)
                        }
                        AlbumArtView(imageKey: step.track.imageKey, size: 44)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.track.title).font(.callout).lineLimit(1)
                            if let a = step.track.artist {
                                Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if (step.track.bpm ?? 0) > 0 || !step.track.camelot.isEmpty {
                                HStack(spacing: Spacing.xs) {
                                    if let bpm = step.track.bpm, bpm > 0 {
                                        Badge("\(Int(bpm)) BPM")
                                    }
                                    if !step.track.camelot.isEmpty {
                                        Badge(step.track.camelot, tint: .roonGold)
                                    }
                                }
                            }
                        }
                        Spacer()
                        if idx > 0 {
                            Text("\(Int(step.similarity * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(step.similarity > 0.7 ? Color.roonSuccess : .secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    if idx < path.count - 1 {
                        HStack(spacing: 0) {
                            Spacer().frame(width: 14)
                            Rectangle()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(width: 2, height: 16)
                        }
                    }
                }
            }
        }
    }

    // MARK: Logic

    private func searchFrom() {
        let q = fromQuery
        guard q.count >= 2 else { fromResults = []; return }
        Task {
            let r = await client.sonicSearch(q)
            fromResults = r
        }
    }

    private func searchTo() {
        let q = toQuery
        guard q.count >= 2 else { toResults = []; return }
        Task {
            let r = await client.sonicSearch(q)
            toResults = r
        }
    }

    private func buildPath() async {
        guard let from = fromTrack, let to = toTrack else { return }
        loading = true
        noResult = false
        defer { loading = false }
        let steps = Int(stepCount)
        let lib = await client.sonicLibrary()
        let index = await client.sonicVectorIndex()
        let result = await Task.detached {
            SongPaths.find(from: from, to: to, library: lib, maxSteps: steps, index: index)
        }.value
        path = result
        noResult = result.isEmpty
        if result.isEmpty { Haptics.error() } else { Haptics.success() }
    }
}
