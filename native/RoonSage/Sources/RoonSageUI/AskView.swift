import RoonSageCore
import SwiftUI

/// In-app natural-language search — type a vibe ("iets donkers en hypnotisch
/// rond 122 BPM") and get an instantly-playable set of library tracks. Uses the
/// configured LLM to map the request to genre/decade/keyword filters, then
/// filters the local cache. Lighter than the Generate flow: one LLM call, no
/// second curation stage — built for quick exploration and immediate playback.
@MainActor
public struct AskView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    @State private var prompt = ""
    @State private var results: [TrackRecord] = []
    @State private var summary: String?
    @State private var working = false

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                TextField("Beschrijf een sfeer… bijv. “donker en hypnotisch rond 122 BPM”", text: $prompt)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canSearch { Task { await search() } } }
                Button {
                    Task { await search() }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Zoek") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSearch || working)
            }

            if let summary { Text(summary).font(.caption).foregroundStyle(.secondary) }

            if working && results.isEmpty {
                SkeletonRows(count: 8)
            } else if results.isEmpty {
                ContentUnavailableView("Vraag het je bibliotheek",
                    systemImage: "text.magnifyingglass",
                    description: Text("Typ een sfeer, genre of tempo en RoonSage vindt passende tracks uit jouw bibliotheek."))
            } else {
                resultsHeader
                List(results, id: \.id) { track in
                    HStack(spacing: Spacing.md) {
                        AlbumArtView(imageKey: track.imageKey, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).lineLimit(1)
                            if let artist = track.artist {
                                Text(artist + (track.year.map { " · \($0)" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Button {
                            queue([track], next: true)
                        } label: { Image(systemName: "text.line.first.and.arrowtriangle.forward") }
                            .buttonStyle(.borderless).help("Als volgende in wachtrij")
                        Button {
                            play([track])
                        } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless).help("Speel nu")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .navigationTitle("Vraag het")
    }

    private var canSearch: Bool { !prompt.trimmingCharacters(in: .whitespaces).isEmpty }

    private var resultsHeader: some View {
        HStack {
            Text("\(results.count) tracks").font(.headline)
            Spacer()
            Button {
                play(results)
            } label: { Label("Speel alles", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(client.selectedZone == nil)
        }
    }

    private func search() async {
        let request = prompt.trimmingCharacters(in: .whitespaces)
        guard !request.isEmpty else { return }
        working = true
        defer { working = false }
        summary = "Bezig met interpreteren…"

        let filters = await client.analyzeForFilters(request: request)
        var opts = DatabaseManager.FilterOptions()
        opts.genres = filters.genres
        opts.decades = filters.decades
        opts.keywords = filters.keywords
        opts.excludeLive = true
        opts.limit = 600
        let pool = await client.filterTracks(options: opts)
        // Hybrid AI: rank the LLM-filtered pool by sonic closeness to the
        // request (CLAP). Falls back to a random pick when embeddings/analyzer
        // text model aren't available.
        if let ranked = await client.sonicRerank(request, pool, limit: 40) {
            results = ranked
            summary = summarise(filters, count: results.count) + " · sonisch gerangschikt"
        } else {
            var tracks = pool
            tracks.shuffle()
            results = Array(tracks.prefix(40))
            summary = summarise(filters, count: results.count)
        }
    }

    private func summarise(_ f: RoonClient.RequestFilters, count: Int) -> String {
        var parts: [String] = []
        if !f.genres.isEmpty { parts.append(f.genres.prefix(3).joined(separator: ", ")) }
        if !f.decades.isEmpty { parts.append(f.decades.map { "\($0)s" }.joined(separator: ", ")) }
        if !f.keywords.isEmpty { parts.append("“\(f.keywords)”") }
        let crit = parts.isEmpty ? "je hele bibliotheek" : parts.joined(separator: " · ")
        return count == 0 ? "Niets gevonden voor \(crit) — probeer het anders te formuleren."
                          : "\(count) tracks uit \(crit)."
    }

    private func play(_ tracks: [TrackRecord]) {
        guard let z = client.selectedZone?.id else { return }
        Haptics.tap()
        Task { await client.curateTracks(tracks, zoneID: z) }
    }

    private func queue(_ tracks: [TrackRecord], next: Bool) {
        guard let z = client.selectedZone?.id else { return }
        Haptics.tap()
        Task { await client.queueTracks(tracks, next: next, zoneID: z) }
    }
}
