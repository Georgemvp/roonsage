import RoonSageCore
import SwiftUI

/// Sonisch zoeken: free-text → audio search (Track E5). The query is embedded by
/// the analyzer's CLAP text encoder (/text-embed) and cosine-ranked against the
/// library's sonic embeddings — so "dreamy late-night piano" finds tracks that
/// *sound* like that, regardless of tags.
@MainActor
public struct SonicSearchView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    @State private var query = ""
    @State private var results: [SonicEngine.Scored] = []
    @State private var loading = false
    @State private var searched = false

    private let examples = ["dromerige ambient piano", "energieke funk met blazers",
                            "donkere melancholische synthwave", "warme akoestische zondagochtend"]

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Beschrijf een sfeer of geluid; de analyzer zet je tekst om in een sonische vector en zoekt nummers die zó klinken.")
                    .font(.callout).foregroundStyle(.secondary)

                searchBar

                ZoneHintBanner()

                if !searched && results.isEmpty {
                    exampleChips
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView(
                        "Geen resultaten",
                        systemImage: "sparkle.magnifyingglass",
                        description: Text("Controleer of de analyzer draait met tekst-zoeken aan en of de sonische kenmerken zijn gesynchroniseerd."))
                } else {
                    resultsList
                }
            }
            .padding()
        }
        .windowWidthCapped()
        .navigationTitle("Sonisch zoeken")
    }

    private var searchBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
            TextField("bijv. dromerige ambient piano", text: $query)
                .textFieldStyle(.plain)
                .onSubmit { runSearch() }
            if !query.isEmpty {
                Button { query = ""; results = []; searched = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.borderless)
            }
            Button { runSearch() } label: { Text(loading ? "Zoeken…" : "Zoek") }
                .buttonStyle(.borderedProminent).tint(Color.roonGold)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || loading)
        }
        .padding(Spacing.sm)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.md))
    }

    private var exampleChips: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Probeer eens").font(.caption).foregroundStyle(.secondary)
            FlowChips(examples) { ex in
                query = ex; runSearch()
            }
        }
    }

    private var topRecords: [TrackRecord] {
        results.prefix(20).map {
            TrackRecord(id: $0.track.id, title: $0.track.title,
                        artist: $0.track.artist, album: $0.track.album)
        }
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("Resultaten (\(results.count))").font(.headline).lineLimit(1)
                Spacer(minLength: Spacing.sm)
                if let zone = client.selectedZone {
                    Button {
                        Haptics.success()
                        Task { await client.curateTracks(topRecords, zoneID: zone.id) }
                    } label: { Label("Speel top 20", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).tint(Color.roonGold).controlSize(.small)
                }
                LocalPlayButton { topRecords }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            ForEach(results.prefix(40)) { scored in
                HStack(spacing: Spacing.md) {
                    AlbumArtView(imageKey: scored.track.imageKey, size: 44)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scored.track.title).font(.callout).lineLimit(1)
                        if let a = scored.track.artist {
                            Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        HStack(spacing: Spacing.xs) {
                            if let bpm = scored.track.bpm, bpm > 0 { Badge("\(Int(bpm)) BPM") }
                            if !scored.track.camelot.isEmpty { Badge(scored.track.camelot, tint: .roonGold) }
                        }
                    }
                    Spacer()
                    if let zone = client.selectedZone {
                        Button {
                            Task { await client.playTrack(id: scored.track.id, title: scored.track.title,
                                                          artist: scored.track.artist, zoneID: zone.id) }
                        } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !loading else { return }
        Haptics.tap()
        loading = true
        searched = true
        Task {
            let r = await client.sonicTextSearch(q, limit: 40)
            await MainActor.run { results = r; loading = false }
        }
    }
}

/// Minimal wrapping chip row for example queries.
private struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void
    init(_ items: [String], onTap: @escaping (String) -> Void) { self.items = items; self.onTap = onTap }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(items, id: \.self) { item in
                Button { onTap(item) } label: {
                    Text(item).font(.callout)
                        .padding(.horizontal, Spacing.sm).padding(.vertical, 6)
                        .background(.background.secondary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
