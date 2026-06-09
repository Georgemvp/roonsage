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
    .init(name: "Sunday Morning",  icon: "sun.horizon",            prompt: "Mellow, peaceful tracks for a relaxed Sunday morning"),
    .init(name: "Workout",         icon: "figure.run",             prompt: "High energy tracks to keep you pumped during a workout"),
    .init(name: "Focus",           icon: "brain",                  prompt: "Calm instrumental tracks ideal for deep focus and concentration"),
    .init(name: "Late Night",      icon: "moon.stars",             prompt: "Moody, atmospheric tracks perfect for late-night listening"),
    .init(name: "Party",           icon: "party.popper",           prompt: "Upbeat, fun tracks to get the party going"),
    .init(name: "Road Trip",       icon: "car.fill",               prompt: "Feel-good, energetic tracks perfect for a long road trip"),
    .init(name: "Dinner Party",    icon: "fork.knife",             prompt: "Sophisticated, tasteful background music for a dinner party"),
    .init(name: "Throwback",       icon: "clock.arrow.circlepath", prompt: "Classic nostalgic tracks from past decades"),
    .init(name: "Chill",           icon: "leaf",                   prompt: "Laid-back, downtempo tracks to unwind to"),
    .init(name: "Rainy Day",       icon: "cloud.rain",             prompt: "Wistful, introspective songs for a grey rainy day"),
    .init(name: "Summer",          icon: "beach.umbrella",         prompt: "Sunny, breezy feel-good tracks for summer"),
    .init(name: "Jazz Café",       icon: "music.quarternote.3",    prompt: "Smooth jazz and soul for a relaxed café atmosphere"),
]

// MARK: - View

@MainActor
struct GenerateView: View {
    @Environment(RoonClient.self) private var client

    @State private var prompt       = ""
    @State private var targetCount  = 20
    @State private var selectedZoneID: String? = nil
    @State private var isGenerating = false
    @State private var phase        = ""
    @State private var generatedTracks: [TrackRecord] = []
    @State private var analysisSummary: String? = nil
    @State private var playlistName = ""
    @State private var justSaved    = false
    @State private var qobuzStatus: String? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {

                // ── Prompt ────────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Text("What kind of playlist?")
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
                    Text("Quick templates")
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
                            Text("Select zone…").tag(Optional<String>.none)
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
                        Label(isGenerating ? "Generating…" : "Generate & Play",
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
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                // ── Result ────────────────────────────────────────────────
                if !generatedTracks.isEmpty {
                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Generated — \(generatedTracks.count) tracks")
                                .font(.headline)
                            if let summary = analysisSummary {
                                Text(summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            if let zoneID = selectedZoneID {
                                Task { await client.curateTracks(generatedTracks, zoneID: zoneID) }
                            }
                        } label: {
                            Label("Play again", systemImage: "play.fill")
                        }
                        .buttonStyle(.bordered)
                    }

                    // Save as local playlist
                    HStack(spacing: 8) {
                        TextField("Playlist name", text: $playlistName)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            let name = playlistName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            _ = client.savePlaylist(name: name, tracks: generatedTracks)
                            justSaved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { justSaved = false }
                        } label: {
                            Label(justSaved ? "Saved!" : "Save playlist", systemImage: "square.and.arrow.down")
                        }
                        .disabled(playlistName.trimmingCharacters(in: .whitespaces).isEmpty)

                        if client.qobuzConfigured {
                            Button {
                                let name = playlistName.trimmingCharacters(in: .whitespaces)
                                guard !name.isEmpty else { return }
                                qobuzStatus = "Saving to Qobuz…"
                                Task {
                                    if let r = await client.saveToQobuz(name: name, tracks: generatedTracks) {
                                        qobuzStatus = "Saved to Qobuz — \(r.matched)/\(r.total) tracks matched."
                                    } else {
                                        qobuzStatus = "Qobuz save failed — check your account in Settings."
                                    }
                                }
                            } label: {
                                Label("Save to Qobuz", systemImage: "cloud")
                            }
                            .disabled(playlistName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if let qobuzStatus {
                        Text(qobuzStatus).font(.caption).foregroundStyle(.secondary)
                    }

                    ForEach(Array(generatedTracks.enumerated()), id: \.offset) { i, t in
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
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Generate Playlist")
        .onAppear {
            if selectedZoneID == nil { selectedZoneID = client.selectedZone?.id }
        }
    }

    // MARK: - Generation logic (analyze → filter → generate)

    private func generate() async {
        isGenerating = true
        errorMessage = nil
        generatedTracks = []
        analysisSummary = nil
        justSaved = false
        defer { isGenerating = false; phase = "" }

        let request = prompt.trimmingCharacters(in: .whitespaces)
        let config = LLMConfigStore.load()

        // Stage 1 — analyse the request into genre/decade filters so the LLM
        // sees RELEVANT tracks (not just the first 300 alphabetically).
        phase = "Analysing…"
        let analysis = await analyzeRequest(request, config: config)

        // Stage 2 — build a varied candidate pool from the filtered library.
        phase = "Selecting candidates…"
        let candidates = buildCandidates(
            genres: analysis.genres, decades: analysis.decades,
            keywords: analysis.keywords, tags: analysis.tags, target: targetCount
        )
        guard !candidates.isEmpty else {
            errorMessage = "No matching tracks — sync your library, or try a broader request."
            return
        }
        analysisSummary = summarise(analysis, poolSize: candidates.count)

        // Stage 3 — curate the final selection.
        phase = "Curating…"
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
                errorMessage = "Could not parse track numbers from response — try again."
                return
            }
            let selected = numbers.compactMap { n -> TrackRecord? in
                guard n >= 1, n <= candidates.count else { return nil }
                return candidates[n - 1]
            }
            generatedTracks = selected
            if playlistName.isEmpty { playlistName = suggestedName(request) }
            if let zoneID = selectedZoneID {
                await client.curateTracks(selected, zoneID: zoneID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private struct Analysis { var genres: [String]; var decades: [Int]; var keywords: String; var tags: [String] }

    /// LLM stage 1: map the request to genres + decades + keywords + mood tags,
    /// each chosen from what the library actually has. Degrades to no filter.
    private func analyzeRequest(_ request: String, config: LLMConfig) async -> Analysis {
        let available = (client.libraryStats()?.topGenres.map { $0.genre }) ?? []
        let availableTags = client.topTags(limit: 60).map { $0.tag }
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
    private func buildCandidates(genres: [String], decades: [Int], keywords: String, tags: [String], target: Int) -> [TrackRecord] {
        let minPool = max(target * 3, 40)
        var opts = DatabaseManager.FilterOptions()
        opts.genres = genres
        opts.decades = decades
        opts.keywords = keywords
        opts.tags = tags
        opts.limit = 3000

        var pool = client.filterTracks(options: opts)
        // Tags are the most specific (and need synced audio features) — drop first.
        if pool.count < minPool, !tags.isEmpty {
            opts.tags = []; pool = client.filterTracks(options: opts)
        }
        if pool.count < minPool, !keywords.isEmpty {
            opts.keywords = ""; pool = client.filterTracks(options: opts)
        }
        if pool.count < minPool, !decades.isEmpty {
            opts.decades = []; pool = client.filterTracks(options: opts)
        }
        if pool.count < minPool, !genres.isEmpty {
            opts.genres = []; pool = client.filterTracks(options: opts)
        }
        pool.shuffle()
        return Array(pool.prefix(400))
    }

    private func summarise(_ a: Analysis, poolSize: Int) -> String {
        var parts: [String] = []
        if !a.genres.isEmpty  { parts.append(a.genres.joined(separator: ", ")) }
        if !a.tags.isEmpty    { parts.append(a.tags.joined(separator: ", ")) }
        if !a.decades.isEmpty { parts.append(a.decades.sorted().map { "\($0)s" }.joined(separator: ", ")) }
        let scope = parts.isEmpty ? "whole library" : parts.joined(separator: " · ")
        return "From \(scope) (\(poolSize) candidates)"
    }

    private func suggestedName(_ request: String) -> String {
        let trimmed = request.prefix(48).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Generated playlist" : String(trimmed)
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
