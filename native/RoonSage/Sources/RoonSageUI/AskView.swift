import RoonSageCore
import SwiftUI

/// In-app natural-language search — type a vibe ("iets donkers en hypnotisch
/// rond 122 BPM") and get an instantly-playable set of library tracks. Uses the
/// shared request analyzer to map the request to genre/decade/tag filters, then
/// filters + sonically ranks the local cache. Lighter than the Generate flow:
/// no second curation stage — built for quick exploration and immediate playback.
///
/// Built on `List` + the native `.searchable()` field (same idiom as
/// `LibraryView`) rather than a hand-rolled search bar in a custom ScrollView —
/// gets the platform-correct search UI for free and sidesteps the iOS 26
/// NavigationStack layout bug custom ScrollView content was vulnerable to.
@MainActor
public struct AskView: View {
    /// Optional handoff: when set (inside the Create-hub), the results gain a
    /// "Verfijn tot playlist →" action that carries the query into Generate —
    /// Ask is Generate's stage 1, so this avoids re-typing the same idea.
    private let onRefine: ((String) -> Void)?
    public init(onRefine: ((String) -> Void)? = nil) { self.onRefine = onRefine }
    @Environment(RoonClient.self) private var client

    @State private var prompt = ""
    @State private var results: [TrackRecord] = []
    @State private var filters: RoonClient.RequestFilters? = nil
    @State private var summary: String?
    @State private var working = false
    @State private var playlistName = ""
    @State private var showSaveAlert = false
    @State private var justSaved = false
    @State private var savedTask: Task<Void, Never>? = nil

    public var body: some View {
        List {
            if working && results.isEmpty {
                Section { SkeletonRows(count: 8) }
                    .listRowSeparator(.hidden)
            } else if results.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Vraag het je bibliotheek", systemImage: "text.magnifyingglass")
                    } description: {
                        Text(summary ?? "Typ een sfeer, genre of tempo en RoonSage vindt passende tracks uit jouw bibliotheek.")
                    }
                    .listRowBackground(Color.clear)
                }
                .listRowSeparator(.hidden)
            } else {
                resultsActionsSection
                Section("Resultaten (\(results.count))") {
                    ForEach(results, id: \.id) { track in
                        AIResultRow(title: track.title, subtitle: subtitle(track), imageKey: track.imageKey) {
                            HStack(spacing: Spacing.sm) {
                                TrackFeedbackButtons(title: track.title, artist: track.artist, album: track.album)
                                Button { queue([track], next: true) } label: {
                                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                        .tappable44()
                                }
                                .buttonStyle(.borderless)
                                .disabled(client.selectedZone == nil)
                                .accessibilityLabel("Zet \(track.title) als volgende in de wachtrij")
                                Button { play([track]) } label: {
                                    Image(systemName: "play.fill")
                                        .tappable44()
                                }
                                .buttonStyle(.borderless)
                                .disabled(client.selectedZone == nil)
                                .accessibilityLabel("Speel \(track.title) nu")
                            }
                        }
                    }
                }
            }
        }
        .task { await client.ensureFeedbackLoaded() }
        .searchable(text: $prompt, prompt: "Beschrijf een sfeer… bijv. “donker en hypnotisch rond 122 BPM”")
        .onSubmit(of: .search) { if canSearch { Task { await search() } } }
        .onChange(of: prompt) { _, newValue in
            if newValue.isEmpty { results = []; summary = nil; filters = nil }
        }
        .navigationTitle("Vraag het")
        .alert("Bewaar als playlist", isPresented: $showSaveAlert) {
            TextField("Naam playlist", text: $playlistName)
            Button("Annuleer", role: .cancel) {}
            Button("Bewaar") { save() }
        } message: {
            Text("Bewaar \(results.count) nummers als lokale playlist.")
        }
    }

    private var canSearch: Bool { !prompt.trimmingCharacters(in: .whitespaces).isEmpty }

    private var resultsActionsSection: some View {
        Section {
            if let filters {
                FilterChips(filters: filters, poolSize: results.count)
                    .padding(.vertical, 2)
            }
            HStack {
                Text("Afspelen op")
                Spacer()
                ZonePicker()
            }
            HStack(spacing: Spacing.sm) {
                Button { play(results) } label: {
                    Label("Speel alles", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(client.selectedZone == nil)

                Button {
                    playlistName = "Vraag: \(prompt.prefix(40))"
                    showSaveAlert = true
                } label: {
                    Label(justSaved ? "Bewaard!" : "Bewaar", systemImage: justSaved ? "checkmark" : "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Bewaar deze tracks als playlist")
            }
            if let onRefine {
                Button { onRefine(prompt) } label: {
                    Label("Verfijn tot playlist →", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Neem deze vraag mee naar Genereer voor een gecureerde, flow-geordende playlist")
            }
        }
    }

    private func subtitle(_ t: TrackRecord) -> String {
        var s = t.artist ?? ""
        if let y = t.year { s += s.isEmpty ? "\(y)" : " · \(y)" }
        return s
    }

    private func search() async {
        let request = prompt.trimmingCharacters(in: .whitespaces)
        guard !request.isEmpty else { return }
        working = true
        defer { working = false }
        // Clear the prior scope so the interim status (not stale chips) shows while
        // the new search runs.
        filters = nil
        summary = "Bezig met interpreteren…"

        let f = await client.analyzeForFilters(request: request)
        var opts = DatabaseManager.FilterOptions()
        opts.genres = f.genres
        opts.decades = f.decades
        opts.keywords = f.keywords
        opts.tags = f.tags
        opts.excludeLive = true
        opts.limit = 600
        var pool = await client.filterTracks(options: opts)
        // Tags need synced audio features — relax them if they emptied the pool.
        if pool.count < 20, !opts.tags.isEmpty {
            opts.tags = []
            pool = await client.filterTracks(options: opts)
        }
        // Taste: softly drop tracks by thumbed-down artists, but only while plenty
        // of pool remains so a niche request still returns results.
        let disliked = Set((await client.feedbackArtistHints()).disliked.map { $0.lowercased() })
        if !disliked.isEmpty {
            let filtered = pool.filter { !disliked.contains(($0.artist ?? "").lowercased()) }
            if filtered.count >= 40 { pool = filtered }
        }
        // Hybrid AI: rank the filtered pool by sonic closeness to the request
        // (CLAP). Falls back to a random pick when embeddings aren't available.
        if let ranked = await client.sonicRerank(request, pool, limit: 40) {
            results = ranked
        } else {
            pool.shuffle()
            results = Array(pool.prefix(40))
        }
        filters = f
        summary = results.isEmpty
            ? "Niets gevonden — probeer het anders te formuleren of synchroniseer je bibliotheek."
            : nil
        if results.isEmpty { Haptics.error() } else { Haptics.success() }
    }

    private func save() {
        guard !results.isEmpty else { return }
        let base = playlistName.trimmingCharacters(in: .whitespaces)
        let name = base.isEmpty ? "Vraag: \(prompt.prefix(40))" : base
        client.savePlaylist(name: String(name), tracks: results)
        Haptics.success()
        justSaved = true
        savedTask?.cancel()
        savedTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            justSaved = false
        }
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
