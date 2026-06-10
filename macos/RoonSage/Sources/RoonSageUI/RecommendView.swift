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

    private let ideas = [
        "Albums for a rainy Sunday afternoon",
        "Deep, immersive records to listen front-to-back",
        "Something jazzy and late-night",
        "Energetic albums to start the day",
    ]

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What are you in the mood for?").font(.headline)
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
                            Text("Select zone…").tag(Optional<String>.none)
                            ForEach(client.zones) { z in
                                Label(z.displayName, systemImage: z.state.icon).tag(Optional(z.id))
                            }
                        }
                        .frame(maxWidth: 200)
                    }
                }

                HStack(spacing: 12) {
                    Button { Task { await recommend() } } label: {
                        Label(isWorking ? "Thinking…" : "Recommend Albums", systemImage: "sparkles")
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
                    Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                }

                if !albums.isEmpty {
                    Divider()
                    if let summary {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(albums, id: \.albumKey) { album in
                        HStack(spacing: 10) {
                            AlbumArtView(imageKey: album.imageKey, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.album).font(.body).lineLimit(1)
                                Text("\(album.artist ?? "Unknown")\(album.year.map { " · \($0)" } ?? "")")
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
            }
            .padding(24)
        }
        .navigationTitle("Recommend")
        .onAppear { if selectedZoneID == nil { selectedZoneID = client.selectedZone?.id } }
    }

    private func recommend() async {
        isWorking = true; errorMessage = nil; albums = []; summary = nil
        defer { isWorking = false; phase = "" }

        let request = prompt.trimmingCharacters(in: .whitespaces)

        phase = "Analysing…"
        let filters = await client.analyzeForFilters(request: request)

        phase = "Gathering albums…"
        let candidates = client.candidateAlbums(filters: filters, limit: 60)
        guard !candidates.isEmpty else {
            errorMessage = "No albums to recommend — sync your library first."
            return
        }

        phase = "Choosing…"
        let list = candidates.enumerated().map { i, a -> String in
            "\(i + 1). \(a.album) — \(a.artist ?? "Unknown")\(a.year.map { " (\($0))" } ?? "")"
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
            guard !numbers.isEmpty else { errorMessage = "Could not parse a recommendation — try again."; return }
            albums = numbers.compactMap { n in (n >= 1 && n <= candidates.count) ? candidates[n - 1] : nil }
            var parts: [String] = []
            if !filters.genres.isEmpty  { parts.append(filters.genres.joined(separator: ", ")) }
            if !filters.decades.isEmpty { parts.append(filters.decades.sorted().map { "\($0)s" }.joined(separator: ", ")) }
            summary = parts.isEmpty ? "From your whole library" : "From \(parts.joined(separator: " · "))"
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
