import RoonSageCore
import SwiftUI

// MARK: - Sonic seed (a jump-off point in the navigable graph)

/// A seed for the sonic-similarity graph: any track can be the centre from which
/// we branch to what *sounds* like it. Identifiable + Hashable so it drives both
/// `.sheet(item:)` and `navigationDestination(for:)` (the recursive "similar of
/// similar" drill-down).
public struct SonicSeed: Identifiable, Hashable, Sendable {
    public let title: String
    public let artist: String?
    public let album: String?
    public let imageKey: String?
    public var id: String { "\(title)\u{1f}\(artist ?? "")" }

    public init(title: String, artist: String?, album: String? = nil, imageKey: String? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.imageKey = imageKey
    }
}

// MARK: - "Sonisch vergelijkbaar" (the graph in its most valuable form)

/// Turns the library's CLAP vector index into a browsable graph: given a seed
/// track, show the nearest-sounding library tracks, let the user play them, and —
/// crucially — let any result become the *next* seed, so you can wander the
/// collection by sound. This is the one surface that makes the sonic engine
/// reachable from everywhere (Now Playing, album tracklists, track Info).
@MainActor
struct SimilarTracksView: View {
    @Environment(RoonClient.self) private var client
    let seed: SonicSeed

    @State private var results: [SonicEngine.Scored] = []
    @State private var loaded = false
    /// Confirmation shown after "Speel deze mix" so the action doesn't read as a
    /// no-op (mirrors the Time Machine journey's "Tijdreis gestart …" banner).
    @State private var confirmation: String?

    private var topRecords: [TrackRecord] {
        results.prefix(30).map { Self.record($0.track) }
    }

    var body: some View {
        List {
            Section {
                header
                if client.hasActiveOutput, !results.isEmpty { playAllRow }
            }
            AsyncStateView(isLoading: !loaded, isEmpty: results.isEmpty) {
                Section("Klinkt hierop") {
                    ForEach(results) { scored in resultRow(scored) }
                }
            } empty: {
                ContentUnavailableView(
                    "Geen sonische match",
                    systemImage: "waveform.slash",
                    description: Text("Dit nummer heeft (nog) geen sonische kenmerken, of de analyzer is niet bereikbaar."))
            }
        }
        .navigationTitle("Vergelijkbaar")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: seed.id) {
            loaded = false
            results = await client.similarTracks(title: seed.title, artist: seed.artist,
                                                 album: seed.album, limit: 40)
            loaded = true
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.md) {
            AlbumArtView(imageKey: seed.imageKey, size: 52, cornerRadius: Radius.md)
            VStack(alignment: .leading, spacing: 2) {
                Text("Vergelijkbaar met").font(.caption).foregroundStyle(.secondary)
                Text(seed.title).font(.headline).lineLimit(1)
                if let a = seed.artist { Text(a).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private var playAllRow: some View {
        VStack(spacing: Spacing.xs) {
            Button {
                Haptics.success()
                let n = topRecords.count
                Task {
                    await client.playToActiveOutput(topRecords)
                    confirmation = "Mix gestart — \(n) tracks."
                }
            } label: {
                Label("Speel deze mix", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Color.roonGold)
            if let confirmation {
                Text(confirmation)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func resultRow(_ scored: SonicEngine.Scored) -> some View {
        let t = scored.track
        // Whole row = drill deeper (this result becomes the next seed) → one
        // clean chevron. The leading play button plays just this track.
        return NavigationLink(value: SonicSeed(title: t.title, artist: t.artist,
                                               album: t.album, imageKey: t.imageKey)) {
            HStack(spacing: Spacing.md) {
                Button {
                    Haptics.tap()
                    Task { await client.playToActiveOutput([Self.record(t)]) }
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .foregroundStyle(client.hasActiveOutput ? Color.roonGold : .secondary)
                }
                .buttonStyle(.borderless)
                .disabled(!client.hasActiveOutput)
                .accessibilityLabel("Speel \(t.title)")

                AlbumArtView(imageKey: t.imageKey, size: 48)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))

                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).font(.callout.weight(.medium)).lineLimit(1)
                    if let a = t.artist {
                        Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    metaLine(scored).font(.caption2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }

    /// Single, non-wrapping metadata line: "92% match · 129 BPM · 10B".
    @ViewBuilder
    private func metaLine(_ scored: SonicEngine.Scored) -> some View {
        let t = scored.track
        HStack(spacing: 5) {
            Text("\(Int(scored.similarity * 100))% match").foregroundStyle(Color.roonGold)
            if let bpm = t.bpm, bpm > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text("\(Int(bpm)) BPM").foregroundStyle(.secondary)
            }
            if !t.camelot.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(t.camelot).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private static func record(_ t: DatabaseManager.SonicTrack) -> TrackRecord {
        TrackRecord(id: t.id, title: t.title, artist: t.artist, album: t.album)
    }
}

// MARK: - Reusable presentation

extension View {
    /// Presents the sonic-similarity graph in a sheet seeded by `item`, wiring the
    /// recursive drill-down so any result can become the next centre. Attach once
    /// per surface that wants a "Sonisch vergelijkbaar" entry point.
    @MainActor
    func similarTracksSheet(item: Binding<SonicSeed?>) -> some View {
        sheet(item: item) { seed in
            NavigationStack {
                SimilarTracksView(seed: seed)
                    .navigationDestination(for: SonicSeed.self) { SimilarTracksView(seed: $0) }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Gereed") { item.wrappedValue = nil }
                        }
                    }
            }
            #if os(iOS)
            .presentationDetents([.large])
            #endif
        }
    }
}
