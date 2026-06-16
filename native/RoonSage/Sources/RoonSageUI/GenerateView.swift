import SwiftUI
import RoonSageCore

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
    @State private var droppedIntentNote: String? = nil
    /// Identities of tracks used by recent generations, newest last — lightly
    /// de-prioritised so repeating a prompt doesn't return the same playlist.
    @State private var recentlyGenerated: [String] = []
    @State private var aiDescription: String? = nil
    @State private var playlistName = ""
    @State private var justSaved    = false
    @State private var qobuzStatus: String? = nil
    @State private var errorMessage: String? = nil
    @State private var showTemplates = false

    /// One featured template per category for quick access; all 63 live
    /// behind "Alle sjablonen".
    private var featured: [PlaylistTemplate] {
        PlaylistTemplates.categories.compactMap { PlaylistTemplates.inCategory($0).first }
    }

    private func apply(_ t: PlaylistTemplate) {
        prompt = t.prompt
        targetCount = [10, 20, 30, 50].min(by: { abs($0 - t.trackCount) < abs($1 - t.trackCount) }) ?? 20
        playlistName = t.name
        Haptics.tap()
    }

    public var body: some View {
        ScrollView {
            #if os(iOS)
            Color.clear.frame(height: 0)
            #endif
            VStack(alignment: .leading, spacing: Spacing.xl) {

                // ── Prompt ────────────────────────────────────────────────
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Wat voor playlist?")
                        .font(.headline)
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(height: 76)
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.sm)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.md))
                }

                // ── Templates ─────────────────────────────────────────────
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack {
                        Text("Snelle sjablonen")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { showTemplates = true } label: {
                            Label("Alle sjablonen", systemImage: "square.grid.2x2")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.sm) {
                            ForEach(featured) { t in
                                Button { apply(t) } label: {
                                    HStack(spacing: Spacing.xs) {
                                        Text(t.icon)
                                        Text(t.name).font(.callout)
                                    }
                                    .padding(.horizontal, Spacing.md)
                                    .padding(.vertical, Spacing.sm)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                }

                // ── Options ───────────────────────────────────────────────
                HStack(spacing: Spacing.lg) {
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
                }

                // ── Generate button ───────────────────────────────────────
                HStack(spacing: Spacing.md) {
                    Button {
                        Task { await generate() }
                    } label: {
                        Label(isGenerating ? "Genereren…" : "Genereer playlist",
                              systemImage: "wand.and.stars")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || isGenerating)

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

                    VStack(alignment: .leading, spacing: Spacing.md) {
                        HStack(alignment: .top, spacing: Spacing.sm) {
                            Image(systemName: "wand.and.stars")
                                .foregroundStyle(Color.roonGold)
                                .symbolEffect(.bounce, value: generatedTracks.count)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlistName.isEmpty ? "Gegenereerde playlist" : playlistName)
                                    .font(.title3.bold())
                                if let aiDescription, !aiDescription.isEmpty {
                                    Text(aiDescription)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                HStack(spacing: 5) {
                                    Text("\(generatedTracks.count) tracks")
                                    if let summary = analysisSummary { Text("· \(summary)") }
                                    if justSaved { Text("· opgeslagen").foregroundStyle(Color.roonGold) }
                                }
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                if let note = droppedIntentNote {
                                    Label(note, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                        }

                        // Play choice — pick a zone, then start it. No auto-play.
                        HStack(spacing: Spacing.sm) {
                            if !client.zones.isEmpty {
                                Picker("Zone", selection: $selectedZoneID) {
                                    Text("Kies zone…").tag(Optional<String>.none)
                                    ForEach(client.zones) { z in
                                        Label(z.displayName, systemImage: z.state.icon).tag(Optional(z.id))
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 220)
                            }
                            Button {
                                if let zoneID = selectedZoneID {
                                    Haptics.tap()
                                    Task { await client.curateTracks(generatedTracks, zoneID: zoneID) }
                                }
                            } label: {
                                Label("Speel af", systemImage: "play.fill").frame(minWidth: 120)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedZoneID == nil)
                        }
                    }

                    // Save as local playlist
                    HStack(spacing: Spacing.sm) {
                        TextField("Naam playlist", text: $playlistName)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            let name = playlistName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            client.savePlaylist(name: name, tracks: generatedTracks)
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
        .sheet(isPresented: $showTemplates) {
            TemplatePicker { t in
                apply(t)
                showTemplates = false
            }
        }
    }

    // MARK: - Generation logic (analyze → filter → generate)

    private func generate() async {
        isGenerating = true
        errorMessage = nil
        generatedTracks = []
        revealedCount = 0
        analysisSummary = nil
        droppedIntentNote = nil
        aiDescription = nil
        justSaved = false
        defer { isGenerating = false; phase = "" }

        let request = prompt.trimmingCharacters(in: .whitespaces)
        let config = client.effectiveLLMConfig()

        // Stage 1 — analyse the request into genre/decade filters so the LLM
        // sees RELEVANT tracks (not just the first 300 alphabetically).
        phase = "Analyseren…"
        let analysis = await analyzeRequest(request, config: config)

        // Stage 2 — build a varied candidate pool from the filtered library.
        phase = "Kandidaten selecteren…"
        let built = await buildCandidates(
            genres: analysis.genres, decades: analysis.decades,
            keywords: analysis.keywords, tags: analysis.tags, target: targetCount
        )
        let pool = built.tracks
        guard !pool.isEmpty else {
            errorMessage = "Geen passende tracks — synchroniseer je bibliotheek of probeer een bredere omschrijving."
            return
        }
        // Hybrid AI: reorder the pool by sonic closeness to the request so the
        // LLM curates from the most relevant candidates first (falls back to the
        // pool order when embeddings/analyzer text model aren't available).
        let candidates = await client.sonicRerank(request, pool, limit: pool.count, maxPerArtist: 50) ?? pool
        // Summarise on the filters that SURVIVED broadening, not what the LLM
        // wanted — so "Uit hele bibliotheek" honestly signals the genre intent
        // couldn't be honoured.
        analysisSummary = summarise(built.survived, poolSize: candidates.count)
        // If the request implied a genre/mood but the library had too few matching
        // tracks, warn rather than silently curating an off-target playlist.
        if (!analysis.genres.isEmpty || !analysis.tags.isEmpty) && built.survived.genres.isEmpty && built.survived.tags.isEmpty {
            droppedIntentNote = "Te weinig tracks voor dit genre in je bibliotheek — gekozen uit de hele bibliotheek."
        } else {
            droppedIntentNote = nil
        }

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

        // Soft curation signals: favour artists the user actually plays (empty on
        // a thin client without history → no effect) and avoid repeating tracks
        // from recent generations.
        let preferred = Set((await client.topArtistsListened(limit: 30)).map { $0.artist.lowercased() })
        let deprioritized = Set(recentlyGenerated)

        do {
            let response = try await LLMClient.shared.complete(system: system, user: user, config: config)
            let numbers  = parseNumbers(from: response, max: candidates.count)
            let llmPicks = numbers.compactMap { n -> TrackRecord? in
                guard n >= 1, n <= candidates.count else { return nil }
                return candidates[n - 1]
            }
            // Deterministic post-pass: dedup, enforce max-2-per-artist + no
            // back-to-back artists, and top up to the target from the ranked pool
            // when the LLM under-delivers (invalid/too-few numbers) instead of
            // erroring or returning a short, clustered list.
            let selected = PlaylistAssembler.assemble(
                llmPicks: llmPicks, pool: candidates, target: targetCount,
                maxPerArtist: 2, preferredArtists: preferred, deprioritized: deprioritized
            )
            guard !selected.isEmpty else {
                errorMessage = "Kon geen playlist samenstellen — probeer een bredere omschrijving."
                return
            }
            // Remember these for anti-repetition next time (cap the trail).
            recentlyGenerated = (recentlyGenerated + selected.map { PlaylistAssembler.identity($0) }).suffix(240).map { $0 }
            revealTracks(selected)

            // Stage 4 — AI title + description, then auto-save locally. No
            // auto-play: the user chooses whether/where via the zone selector.
            phase = "Titel & beschrijving…"
            let meta = await describePlaylist(request: request, tracks: selected, config: config)
            playlistName = meta.title
            aiDescription = meta.description
            client.savePlaylist(name: meta.title, tracks: selected)
            justSaved = true
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

    /// LLM stage 4: an evocative Dutch title + a one-line description for the
    /// curated set. Falls back to a heuristic name (no description) on failure.
    private func describePlaylist(request: String, tracks: [TrackRecord], config: LLMConfig) async -> (title: String, description: String?) {
        let sample = tracks.prefix(30).map { t -> String in
            var s = t.title
            if let a = t.artist { s += " — \(a)" }
            return s
        }.joined(separator: "\n")
        let system = """
        You name and describe a music playlist in Dutch. \
        Respond with ONLY a JSON object, no prose: {"title": "", "description": ""} \
        - title: a short, evocative name (max 5 words), no surrounding quotes, no emoji. \
        - description: one or two warm sentences capturing the mood and vibe of the set.
        """
        let user = "Verzoek van de gebruiker: \(request)\n\nTracks:\n\(sample)"
        guard let resp = try? await LLMClient.shared.complete(system: system, user: user, config: config),
              let obj = extractJSON(resp) else {
            return (suggestedName(request), nil)
        }
        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc  = (obj["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == false ? title! : suggestedName(request),
                desc?.isEmpty == false ? desc : nil)
    }

    private struct Analysis { var genres: [String]; var decades: [Int]; var keywords: String; var tags: [String] }

    /// LLM stage 1: map the request to genres + decades + keywords + mood tags,
    /// each chosen from what the library actually has. Degrades to no filter.
    private func analyzeRequest(_ request: String, config: LLMConfig) async -> Analysis {
        // Use the FULL genre vocabulary (not just top-20) so smaller genres stay
        // selectable. Roon's taxonomy is coarse (~21 top-level genres, e.g. one
        // "Jazz", no sub-styles), so the model is told to map sub-styles to their
        // parent, with substring matching below as a safety net.
        let available = await client.allGenres(limit: 200)
        let availableTags = (await client.topTags(limit: 60)).map { $0.tag }
        guard !available.isEmpty || !availableTags.isEmpty else {
            return Analysis(genres: [], decades: [], keywords: "", tags: [])
        }

        let genreList = available.prefix(80).joined(separator: ", ")
        let tagLine = availableTags.isEmpty ? ""
            : "\n- tags: 0-5 mood/vibe tags chosen EXACTLY from this list that fit the request: \(availableTags.prefix(50).joined(separator: ", "))"
        let system = """
        You map a music playlist request to library filters. \
        Respond with ONLY a JSON object, no prose: \
        {"genres": [], "decades": [], "keywords": "", "tags": []} \
        - genres: 0-6 names copied VERBATIM from the available list that fit the request's mood/style. The list is the COMPLETE vocabulary — never invent names. Map any sub-style in the request to its closest PARENT in the list (e.g. bebop/swing/smooth jazz/hard bop -> "Jazz"; techno/house -> the closest electronic name; baroque/opera -> "Classical"). Empty = no genre constraint. \
        - decades: 0-3 decade start years like 1980 if an era is implied, else []. \
        - keywords: short extra search terms for title/artist, or "".\(tagLine)
        Available genres: \(genreList)
        """
        guard let resp = try? await LLMClient.shared.complete(system: system, user: "Request: \(request)", config: config),
              let obj = extractJSON(resp) else {
            return Analysis(genres: [], decades: [], keywords: "", tags: [])
        }

        // Expand each model-picked genre to every library genre it overlaps with,
        // so "jazz" also pulls in "Vocal Jazz", "Jazz Fusion", "Cool Jazz", etc.
        // (exact equality alone left these out → empty filter → whole-library
        // fallback that ignored the request). Bidirectional substring match.
        let picked = (obj["genres"] as? [Any])?.compactMap { ($0 as? String)?.lowercased() } ?? []
        var matched: [String] = []
        var seen = Set<String>()
        for p in picked where !p.isEmpty {
            for g in available {
                let gl = g.lowercased()
                guard gl.contains(p) || p.contains(gl) else { continue }
                if seen.insert(gl).inserted { matched.append(g) }
            }
        }
        let genres = matched
        let decades = (obj["decades"] as? [Any])?.compactMap { ($0 as? Int) ?? Int(String(describing: $0)) } ?? []
        let keywords = (obj["keywords"] as? String) ?? ""
        let tagSet = Set(availableTags.map { $0.lowercased() })
        let tags = (obj["tags"] as? [Any])?.compactMap { ($0 as? String)?.lowercased() }.filter { tagSet.contains($0) } ?? []
        return Analysis(genres: genres, decades: decades, keywords: keywords, tags: tags)
    }

    /// Filter the library by the analysed criteria, broadening if too sparse,
    /// then shuffle so the LLM sees a varied sample rather than an A→Z slice.
    private func buildCandidates(genres: [String], decades: [Int], keywords: String, tags: [String], target: Int) async -> (tracks: [TrackRecord], survived: Analysis) {
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
        // Report the filters that actually survived broadening so the summary is
        // honest about whether the request's genre intent really constrained the
        // pool (or quietly fell back to the whole library).
        let survived = Analysis(genres: opts.genres, decades: opts.decades, keywords: opts.keywords, tags: opts.tags)
        return (Array(pool.prefix(400)), survived)
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

// MARK: - Template picker sheet

/// Browse all 63 built-in templates by category. Picking one fills the prompt.
@MainActor
private struct TemplatePicker: View {
    let onPick: (PlaylistTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var category = PlaylistTemplates.categories.first ?? "Sfeer"

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.md)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(PlaylistTemplates.categories, id: \.self) { cat in
                            let isOn = cat == category
                            Button {
                                withAnimation(Motion.quick) { category = cat }
                            } label: {
                                Text(cat)
                                    .font(.callout.weight(isOn ? .semibold : .regular))
                                    .padding(.horizontal, Spacing.md)
                                    .padding(.vertical, Spacing.sm)
                                    .background(isOn ? AnyShapeStyle(Color.roonGold) : AnyShapeStyle(.quaternary),
                                                in: Capsule())
                                    .foregroundStyle(isOn ? Color.black : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                }

                ScrollView {
                    LazyVGrid(columns: columns, spacing: Spacing.md) {
                        ForEach(PlaylistTemplates.inCategory(category)) { t in
                            Button { onPick(t) } label: { card(t) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(Spacing.lg)
                }
            }
            .navigationTitle("Sjablonen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("Sluit") { dismiss() }
            }
        }
    }

    private func card(_ t: PlaylistTemplate) -> some View {
        VStack(spacing: Spacing.xs) {
            Text(t.icon).font(.system(size: 34))
            Text(t.name)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("\(t.trackCount) tracks")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .padding(Spacing.md)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(Color.roonGold.opacity(0.15))
        )
        .accessibilityLabel("\(t.name), \(t.trackCount) tracks")
    }
}
