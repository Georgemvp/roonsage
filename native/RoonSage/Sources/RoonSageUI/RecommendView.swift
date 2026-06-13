import SwiftUI
import RoonSageCore

/// Album-level recommendations: describe a vibe, the LLM picks albums from your
/// library to explore (library-first). Each recommendation is playable.
@MainActor
public struct RecommendView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    @State private var prompt        = ""
    @State private var count         = 8
    @State private var selectedZoneID: String? = nil
    @State private var isWorking     = false
    @State private var phase         = ""
    @State private var albums: [DatabaseManager.AlbumResult] = []
    @State private var summary: String? = nil
    @State private var errorMessage: String? = nil

    @State private var history: [DatabaseManager.RecommendationSummary] = []
    @State private var expandedHistoryID: Int64? = nil
    @State private var historyAlbums: [DatabaseManager.AlbumResult] = []

    private let ideas = [
        "Albums voor een regenachtige zondagmiddag",
        "Diepe, meeslepende platen om van begin tot eind te luisteren",
        "Iets jazzy voor laat op de avond",
        "Energieke albums om de dag mee te beginnen",
    ]

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if client.genreCount == 0 {
                    Label("Genres zijn niet gesynchroniseerd. Ga naar Instellingen → \"Synchroniseer genres\" voor betere aanbevelingen.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Waar heb je zin in?").font(.headline)
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(height: 70)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 8) {
                        ForEach(ideas, id: \.self) { idea in
                            Button { prompt = idea } label: {
                                Text(idea).font(.caption).frame(maxWidth: .infinity).padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Text("Albums").foregroundStyle(.secondary)
                        Picker("Albums", selection: $count) {
                            ForEach([5, 8, 12], id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented).frame(width: 150).labelsHidden()
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

                HStack(spacing: 12) {
                    Button { Task { await recommend() } } label: {
                        Label(isWorking ? "Denken…" : "Beveel albums aan", systemImage: "sparkles")
                            .frame(minWidth: 190)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                    if isWorking {
                        ProgressView().controlSize(.small)
                        Text(phase).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let err = errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(Color.roonDanger).font(.callout)
                }

                if !albums.isEmpty {
                    Divider()
                    if let summary {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                    albumList(albums)
                }

                // History
                if !history.isEmpty {
                    Divider()
                    Text("Eerdere aanbevelingen")
                        .font(.headline)

                    ForEach(history, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.prompt)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text("\(entry.albumCount) albums · \(formatDate(entry.createdAt))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    Task { await toggleHistory(entry) }
                                } label: {
                                    Image(systemName: expandedHistoryID == entry.id ? "chevron.up" : "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                Button(role: .destructive) {
                                    client.deleteRecommendation(id: entry.id)
                                    history.removeAll { $0.id == entry.id }
                                    if expandedHistoryID == entry.id {
                                        expandedHistoryID = nil
                                        historyAlbums = []
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await toggleHistory(entry) } }

                            if expandedHistoryID == entry.id {
                                albumList(historyAlbums)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
            .padding(Spacing.xl)
        }
        .navigationTitle("Aanbevelen")
        .onAppear {
            if selectedZoneID == nil { selectedZoneID = client.selectedZone?.id }
            Task { history = await client.recommendations() }
        }
    }

    @ViewBuilder
    private func albumList(_ items: [DatabaseManager.AlbumResult]) -> some View {
        ForEach(items, id: \.albumKey) { album in
            HStack(spacing: 10) {
                AlbumArtView(imageKey: album.imageKey, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.album).font(.body).lineLimit(1)
                    Text("\(album.artist ?? "Onbekend")\(album.year.map { " · \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    guard let zone = selectedZoneID else { return }
                    Task { await client.playAlbum(albumKey: album.albumKey, zoneID: zone) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(selectedZoneID == nil)
            }
            .padding(.vertical, 2)
        }
    }

    private func toggleHistory(_ entry: DatabaseManager.RecommendationSummary) async {
        if expandedHistoryID == entry.id {
            expandedHistoryID = nil
            historyAlbums = []
        } else {
            expandedHistoryID = entry.id
            historyAlbums = await client.recommendationAlbums(id: entry.id)
        }
    }

    private func formatDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) {
            let rel = RelativeDateTimeFormatter()
            rel.locale = Locale(identifier: "nl_NL")
            return rel.localizedString(for: d, relativeTo: Date())
        }
        return iso
    }

    private func recommend() async {
        isWorking = true; errorMessage = nil; albums = []; summary = nil
        defer { isWorking = false; phase = "" }

        let request = prompt.trimmingCharacters(in: .whitespaces)

        phase = "Analyseren…"
        let filters = await client.analyzeForFilters(request: request)

        phase = "Albums verzamelen…"
        let candidates = await client.candidateAlbums(filters: filters, limit: 60)
        guard !candidates.isEmpty else {
            errorMessage = "Geen albums om aan te bevelen — synchroniseer eerst je bibliotheek."
            return
        }

        phase = "Kiezen…"
        let list = candidates.enumerated().map { i, a -> String in
            var line = "\(i + 1). \(a.album) — \(a.artist ?? "Unknown")\(a.year.map { " (\($0))" } ?? "")"
            if !a.genres.isEmpty { line += " [\(a.genres.prefix(3).joined(separator: ", "))]" }
            return line
        }.joined(separator: "\n")
        let system = """
        You recommend albums for a personal music library. From the numbered album list, \
        choose exactly \(count) albums that best match the request. Favor a variety of artists. \
        Return ONLY the album numbers separated by commas — no explanation. Example: 3, 11, 2, 8
        """
        let user = "Request: \(request)\n\nAvailable albums:\n\(list)"

        do {
            let resp = try await LLMClient.shared.complete(system: system, user: user, config: LLMConfigStore.load())
            let numbers = parseNumbers(from: resp, max: candidates.count)
            guard !numbers.isEmpty else { errorMessage = "Kon de aanbeveling niet verwerken — probeer opnieuw."; return }
            albums = numbers.compactMap { n in (n >= 1 && n <= candidates.count) ? candidates[n - 1] : nil }
            var parts: [String] = []
            if !filters.genres.isEmpty  { parts.append(filters.genres.joined(separator: ", ")) }
            if !filters.decades.isEmpty { parts.append(filters.decades.sorted().map { "\($0)s" }.joined(separator: ", ")) }
            summary = parts.isEmpty ? "Uit je hele bibliotheek" : "Uit \(parts.joined(separator: " · "))"

            // Persist to history
            client.saveRecommendation(prompt: request, albums: albums)
            history = await client.recommendations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func parseNumbers(from text: String, max: Int) -> [Int] {
        let clean = text.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        return clean.components(separatedBy: .init(charactersIn: ", ;\n\t"))
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 >= 1 && $0 <= max }
    }
}
