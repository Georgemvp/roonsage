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
]

// MARK: - View

@MainActor
struct GenerateView: View {
    @Environment(RoonClient.self) private var client

    @State private var prompt       = ""
    @State private var targetCount  = 20
    @State private var selectedZoneID: String? = nil
    @State private var isGenerating = false
    @State private var generatedTracks: [TrackRecord] = []
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

                    if isGenerating { ProgressView().controlSize(.small) }
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
                        Text("Generated — \(generatedTracks.count) tracks")
                            .font(.headline)
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

                    ForEach(Array(generatedTracks.enumerated()), id: \.offset) { i, t in
                        HStack(spacing: 10) {
                            Text("\(i + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 28, alignment: .trailing)
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

    // MARK: - Generation logic

    private func generate() async {
        isGenerating = true
        errorMessage = nil
        generatedTracks = []
        defer { isGenerating = false }

        var opts = DatabaseManager.FilterOptions()
        opts.limit = 300
        let tracks = client.filterTracks(options: opts)

        guard !tracks.isEmpty else {
            errorMessage = "Library is empty — sync your library first."
            return
        }

        let list = tracks.enumerated().map { i, t -> String in
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
        let user = "Request: \(prompt.trimmingCharacters(in: .whitespaces))\n\nAvailable tracks:\n\(list)"

        let config = LLMConfigStore.load()
        do {
            let response = try await LLMClient.shared.complete(system: system, user: user, config: config)
            let numbers  = parseNumbers(from: response, max: tracks.count)
            guard !numbers.isEmpty else {
                errorMessage = "Could not parse track numbers from response — try again."
                return
            }
            let selected = numbers.compactMap { n -> TrackRecord? in
                guard n >= 1, n <= tracks.count else { return nil }
                return tracks[n - 1]
            }
            generatedTracks = selected
            if let zoneID = selectedZoneID {
                await client.curateTracks(selected, zoneID: zoneID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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
