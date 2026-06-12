import SwiftUI
import RoonSageCore

// MARK: - Templates

private struct PlaylistTemplate: Identifiable {
    let id   = UUID()
    let name: String
    let icon: String
    let prompt: String
}

private let templates: [PlaylistTemplate] = [
    .init(name: "Zondagochtend",   icon: "sun.horizon",            prompt: "Mellow, peaceful tracks for a relaxed Sunday morning"),
    .init(name: "Workout",         icon: "figure.run",             prompt: "High energy tracks to keep you pumped during a workout"),
    .init(name: "Focus",           icon: "brain",                  prompt: "Calm instrumental tracks ideal for deep focus and concentration"),
    .init(name: "Late avond",      icon: "moon.stars",             prompt: "Moody, atmospheric tracks perfect for late-night listening"),
    .init(name: "Party",           icon: "party.popper",           prompt: "Upbeat, fun tracks to get the party going"),
    .init(name: "Roadtrip",        icon: "car.fill",               prompt: "Feel-good, energetic tracks perfect for a long road trip"),
    .init(name: "Etentje",         icon: "fork.knife",             prompt: "Sophisticated, tasteful background music for a dinner party"),
    .init(name: "Throwback",       icon: "clock.arrow.circlepath", prompt: "Classic nostalgic tracks from past decades"),
    .init(name: "Chill",           icon: "leaf",                   prompt: "Laid-back, downtempo tracks to unwind to"),
    .init(name: "Regendag",        icon: "cloud.rain",             prompt: "Wistful, introspective songs for a grey rainy day"),
    .init(name: "Zomer",           icon: "beach.umbrella",         prompt: "Sunny, breezy feel-good tracks for summer"),
    .init(name: "Jazzcafé",        icon: "music.quarternote.3",    prompt: "Smooth jazz and soul for a relaxed café atmosphere"),
]

// MARK: - View

@MainActor
public struct GenerateView: View {
    public init() {}
    @Environment(RoonClient.self) private var client
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var prompt       = ""
    @State private var targetCount  = 20
    @State private var selectedZoneID: String? = nil
    @State private var isGenerating = false
    @State private var phase        = ""
    @State private var generatedTracks: [TrackRecord] = []
    /// Rows revealed so far — the curation result "deals out" with a short
    /// stagger instead of dumping a list (the payoff for the LLM wait).
    @State private var revealedCount = 0
    @State private var revealTask: Task<Void, Never>? = nil
    @State private var analysisSummary: String? = nil
    @State private var playlistName = ""
    @State private var justSaved    = false
    @State private var qobuzStatus: String? = nil
    @State private var errorMessage: String? = nil

    public var body: some View {
        ScrollView {
            #if os(iOS)
            Color.clear.frame(height: 0)
            #endif
            VStack(alignment: .leading, spacing: Spacing.xl) {

                // ── Prompt ────────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Text("Wat voor playlist?")
                        .font(.headline)
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(height: 76)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }

                // ── Templates ─────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Text("Snelle sjablonen")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 8) {
                        ForEach(templates) { t in
                            Button { prompt = t.prompt } label: {
                                Label(t.name, systemImage: t.icon)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                // ── Options ───────────────────────────────────────────────
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Text("Tracks")
                            .foregroundStyle(.secondary)
                        Picker("Tracks", selection: $targetCount) {
                            Text("10").tag(10)
                            Text("20").tag(20)
                            Text("30").tag(30)
                            Text("50").tag(50)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                        .labelsHidden()
                    }

                    Spacer()

                    if !client.zones.isEmpty {
                        Picker("Zone", selection: $selectedZoneID) {
                            Text("Kies zone…").tag(Optional<String>.none)
                            ForEach(client.zones) { z in
                                Label(z.displayName, systemImage: z.state.icon).tag(Optional(z.id))
                            }
                        }
                        .frame(maxWidth: 200)
                    }
                }

                // ── Generate button ───────────────────────────────────────
                HStack(spacing: 12) {
                    Button {
                        Task { await generate() }
                    } label: {
                        Label(isGenerating ? "Genereren…" : "Genereer & speel",
                              systemImage: "wand.and.stars")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty
                              || isGenerating
                              || selectedZoneID == nil)

                    if isGenerating {
                        ProgressView().controlSize(.small)
                        Text(phase).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let err = errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.roonDanger)
                        .font(.callout)
                }

                // ── Result ────────────────────────────────────────────────
                if !generatedTracks.isEmpty {
                    Divider()

                    HStack {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(Color.roonGold)
                            .symbolEffect(.bounce, value: generatedTracks.count)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Gegenereerd — \(generatedTracks.count) tracks")
                                .font(.headline)
                            if let summary = analysisSummary {
                                Text(summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            if let zoneID = selectedZoneID {
                                Haptics.tap()
                                Task { await client.curateTracks(generatedTracks, zoneID: zoneID) }
                            }
                        } label: {
                            Label("Speel opnieuw", systemImage: "play.fill")
                        }
                        .buttonStyle(.bordered)
                    }

                    // Save as local playlist
                    HStack(spacing: 8) {
                        TextField("Naam playlist", text: $playlistName)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            let name = playlistName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            _ = client.savePlaylist(name: name, tracks: generatedTracks)
                            Haptics.success()
                            justSaved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { justSaved = false }
                        } label: {
                            Label(justSaved ? "Bewaard!" : "Bewaar playlist", systemImage: "square.and.arrow.down")
                        }
                        .disabled(playlistName.trimmingCharacters(in: .whitespaces).isEmpty)

                        if client.qobuzConfigured {
                            Button {
                                let name = playlistName.trimmingCharacters(in: .whitespaces)
                                guard !name.isEmpty else { return }
                                qobuzStatus = "Bewaren in Qobuz…"
                                Task {
                                    if let r = await client.saveToQobuz(name: name, tracks: generatedTracks) {
                                        qobuzStatus = "Bewaard in Qobuz — \(r.matched)/\(r.total) tracks gematcht."
                                    } else {
                                        qobuzStatus = "Bewaren in Qobuz mislukt — controleer je account in Instellingen."
                                    }
                                }
                            } label: {
                                Label("Bewaar in Qobuz", systemImage: "cloud")
                            }
                            .disabled(playlistName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if let qobuzStatus {
                        Text(qobuzStatus).font(.caption).foregroundStyle(.secondary)
                    }

                    // Rows deal out one by one (30 ms stagger, spring) —
                    // see revealTracks(). Reduce-motion shows them at once.
                    ForEach(Array(generatedTracks.prefix(revealedCount).enumerated()), id: \.offset) { i, t in
                        HStack(spacing: 10) {
                            Text("\(i + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 28, alignment: .trailing)
                            AlbumArtView(imageKey: t.imageKey, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.body).lineLimit(1)
                                if let a = t.artist {
                                    Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if let y = t.year {
                                Text(String(y))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .padding(Spacing.xl)
        }
        .navigationTitle("Playlist genereren")
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .onAppear {
            if selectedZoneID == nil { selectedZoneID = client.selectedZone?.id }
        }
    }

    // MARK: - Generation logic (analyze → filter → generate)

    private func generate() async {
        isGenerating = true
        errorMessage = nil
        generatedTracks = []
        revealedCount = 0
        analysisSummary = nil
        justSaved = false
        defer { isGenerating = false; phase = "" }

        let request = prompt.trimmingCharacters(in: .whitespaces)
        let config = LLMConfigStore.load()

        // Stage 1 — analyse the request into genre/decade filters so the LLM
        // sees RELEVANT tracks (not just the first 300 alphabetically).
        phase = "Analyseren…"
        let analysis = await analyzeRequest(request, config: config)

        // Stage 2 — build a varied candidate pool from the filtered library.
        phase = "Kandidaten selecteren…"
        let candidates = await buildCandidates(
            genres: analysis.genres, decades: analysis.decades,
            keywords: analysis.keywords, tags: analysis.tags, target: targetCount
        )
        guard !candidates.isEmpty else {
            errorMessage = "Geen passende tracks — synchroniseer je bibliotheek of probeer een bredere omschrijving."
            return
        }
        analysisSummary = summarise(analysis, poolSize: candidates.count)

        // Stage 3 — curate the final selection.
        phase = "Cureren…"
        let list = candidates.enumerated().map { i, t -> String in
            var s = "\(i + 1). \(t.title)"
            if let a = t.artist { s += " — \(a)" }
            if let y = t.year   { s += " (\(y))" }
            return s
        }.joined(separator: "\n")

        let system = """
        You are a music curator for a personal Roon music player. \
        Select exactly \(targetCount) tracks from the numbered list that best match the request. \
        Rules: max 2 tracks per artist, no two consecutive tracks by the same artist, ensure variety. \
        Return ONLY the track numbers separated by commas — no explanation, no extra text. \
        Example: 3, 17, 42, 8, 91
        """
        let user = "Request: \(request)\n\nAvailable tracks:\n\(list)"

        do {
            let response = try await LLMClient.shared.complete(system: system, user: user, config: config)
            let numbers  = parseNumbers(from: response, max: candidates.count)
            guard !numbers.isEmpty else {
                errorMessage = "Kon geen tracknummers uit het antwoord halen — probeer opnieuw."
                return
            }
            let selected = numbers.compactMap { n -> TrackRecord? in
                guard n >= 1, n <= candidates.count else { return nil }
                return candidates[n - 1]
            }
            revealTracks(selected)
            if playlistName.isEmpty { playlistName = suggestedName(request) }
            if let zoneID = selectedZoneID {
                await client.curateTracks(selected, zoneID: zoneID)
            }
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    /// Deal the curated rows out with a 30 ms stagger — like cards being laid
    /// on a table. Success haptic fires once when the result lands.
    private func revealTracks(_ tracks: [TrackRecord]) {
        revealTask?.cancel()
        generatedTracks = tracks
        Haptics.success()
        guard !reduceMotion else { revealedCount = tracks.count; return }
        revealedCount = 0
        revealTask = Task {
            for i in 1...tracks.count {
                try? await Task.sleep(nanoseconds: 30_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(Motion.spring) { revealedCount = i }
            }
        }
    }

    private struct Analysis { var genres: [String]; var decades: [Int]; var keywords: String; var tags: [String] }

    /// LLM stage 1: map the request to genres + decades + keywords + mood tags,
    /// each chosen from what the library actually has. Degrades to no filter.
    private func analyzeRequest(_ request: String, config: LLMConfig) async -> Analysis {
        let available = ((await client.libraryStats())?.topGenres.map { $0.genre }) ?? []
        let availableTags = (await client.topTags(limit: 60)).map { $0.tag }
        guard !available.isEmpty || !availableTags.isEmpty else {
            return Analysis(genres: [], decades: [], keywords: "", tags: [])
        }

        let genreList = available.prefix(40).joined(separator: ", ")
        let tagLine = availableTags.isEmpty ? ""
            : "\n- tags: 0-5 mood/vibe tags chosen EXACTLY from this list that fit the request: \(availableTags.prefix(50).joined(separator: ", "))"
        let system = """
        You map a music playlist request to library filters. \
        Respond with ONLY a JSON object, no prose: \
        {"genres": [], "decades": [], "keywords": "", "tags": []} \
        - genres: 0-6 names chosen EXACTLY from the available list that fit the request's mood/style. Empty = no genre constraint. \
        - decades: 0-3 decade start years like 1980 if an era is implied, else []. \
        - keywords: short extra search terms for title/artist, or "".\(tagLine)
        Available genres: \(genreList)
        """
        guard let resp = try? await LLMClient.shared.complete(system: system, user: "Request: \(request)", config: config),
              let obj = extractJSON(resp) else {
            return Analysis(genres: [], decades: [], keywords: "", tags: [])
        }

        var canonicalGenres: [String: String] = [:]
        for g in available { canonicalGenres[g.lowercased()] = g }
        let genres = (obj["genres"] as? [Any])?.compactMap { ($0 as? String)?.lowercased() }.compactMap { canonicalGenres[$0] } ?? []
        let decades = (obj["decades"] as? [Any])?.compactMap { ($0 as? Int) ?? Int(String(describing: $0)) } ?? []
        let keywords = (obj["keywords"] as? String) ?? ""
        let tagSet = Set(availableTags.map { $0.lowercased() })
        let tags = (obj["tags"] as? [Any])?.compactMap { ($0 as? String)?.lowercased() }.filter { tagSet.contains($0) } ?? []
        return Analysis(genres: genres, decades: decades, keywords: keywords, tags: tags)
    }

    /// Filter the library by the analysed criteria, broadening if too sparse,
    /// then shuffle so the LLM sees a varied sample rather than an A→Z slice.
    private func buildCandidates(genres: [String], decades: [Int], keywords: String, tags: [String], target: Int) async -> [TrackRecord] {
        let minPool = max(target * 3, 40)
        var opts = DatabaseManager.FilterOptions()
        opts.genres = genres
        opts.decades = decades
        opts.keywords = keywords
        opts.tags = tags
        opts.limit = 3000

        var pool = await client.filterTracks(options: opts)
        // Tags are the most specific (and need synced audio features) — drop first.
        if pool.count < minPool, !tags.isEmpty {
            opts.tags = []; pool = await client.filterTracks(options: opts)
        }
        if pool.count < minPool, !keywords.isEmpty {
            opts.keywords = ""; pool = await client.filterTracks(options: opts)
        }
        if pool.count < minPool, !decades.isEmpty {
            opts.decades = []; pool = await client.filterTracks(options: opts)
        }
        if pool.count < minPool, !genres.isEmpty {
            opts.genres = []; pool = await client.filterTracks(options: opts)
        }
        pool.shuffle()
        return Array(pool.prefix(400))
    }

    private func summarise(_ a: Analysis, poolSize: Int) -> String {
        var parts: [String] = []
        if !a.genres.isEmpty  { parts.append(a.genres.joined(separator: ", ")) }
        if !a.tags.isEmpty    { parts.append(a.tags.joined(separator: ", ")) }
        if !a.decades.isEmpty { parts.append(a.decades.sorted().map { "\($0)s" }.joined(separator: ", ")) }
        let scope = parts.isEmpty ? "hele bibliotheek" : parts.joined(separator: " · ")
        return "Uit \(scope) (\(poolSize) kandidaten)"
    }

    private func suggestedName(_ request: String) -> String {
        let trimmed = request.prefix(48).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Gegenereerde playlist" : String(trimmed)
    }

    private func extractJSON(_ text: String) -> [String: Any]? {
        let clean = text.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression
        )
        guard let start = clean.firstIndex(of: "{"), let end = clean.lastIndex(of: "}"), start < end else { return nil }
        let json = String(clean[start...end])
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    private func parseNumbers(from text: String, max: Int) -> [Int] {
        let clean = text.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression
        )
        return clean
            .components(separatedBy: .init(charactersIn: ", ;\n\t"))
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 >= 1 && $0 <= max }
    }
}
