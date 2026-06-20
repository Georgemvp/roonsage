import SwiftUI
import RoonSageCore

// MARK: - View

/// AI playlist generation. The whole analyse → candidates → curate → name
/// pipeline now lives in `RoonClient.generatePlaylist` (Core); this view only
/// owns the prompt, the staged-progress display and an *editable* result the
/// user can refine (play/queue/reorder/remove a track) before saving.
@MainActor
public struct GenerateView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    @State private var prompt        = ""
    @State private var targetCount   = 20
    @State private var isGenerating  = false
    @State private var phase: RoonClient.GenerationPhase? = nil
    @State private var genTask: Task<Void, Never>? = nil
    /// Monotonic token so a cancelled/superseded run can't reset shared @State or
    /// publish a result under a newer run.
    @State private var genToken      = 0

    @State private var result: RoonClient.GenerationResult? = nil
    /// Editable working copy of the curated tracks (mutated by the row actions).
    @State private var tracks: [TrackRecord] = []

    @State private var playlistName = ""
    @State private var justSaved    = false
    @State private var savedTask: Task<Void, Never>? = nil
    @State private var qobuzStatus: String? = nil
    @State private var errorMessage: String? = nil
    @State private var showTemplates = false

    /// One featured template per category for quick access; all 63 live behind
    /// "Alle sjablonen".
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
                promptSection
                templatesSection
                optionsSection
                generateSection

                if let err = errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.roonDanger)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }

                if isGenerating {
                    GenerationStepper(current: phase ?? .analyzing)
                        .transition(.opacity)
                }

                if isGenerating, result == nil {
                    loadingState
                } else if let result {
                    resultSection(result)
                } else {
                    idleState
                }
            }
            .padding(Spacing.xl)
            .animation(Motion.standard, value: result?.title)
            .animation(Motion.quick, value: errorMessage)
        }
        .navigationTitle("Playlist genereren")
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .sheet(isPresented: $showTemplates) {
            TemplatePicker { t in apply(t); showTemplates = false }
        }
    }

    // MARK: Form

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Wat voor playlist?").font(.headline)
            AIPromptField(text: $prompt,
                          placeholder: "Beschrijf de sfeer, het genre of de gelegenheid… bijv. “warme jazz voor een regenachtige zondagochtend”")
        }
    }

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("Snelle sjablonen")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showTemplates = true } label: {
                    Label("Alle sjablonen", systemImage: "square.grid.2x2").font(.caption)
                }
                .buttonStyle(.borderless)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(featured) { t in
                        Button { apply(t) } label: {
                            HStack(spacing: Spacing.xs) {
                                Text(t.icon)
                                Text(t.name).font(.callout).lineLimit(1)
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    private var optionsSection: some View {
        HStack(spacing: Spacing.lg) {
            HStack(spacing: Spacing.xs) {
                Text("Tracks").foregroundStyle(.secondary)
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
            ZonePicker()
        }
    }

    private var generateSection: some View {
        HStack(spacing: Spacing.md) {
            Button { startGenerate() } label: {
                Label(generateButtonTitle, systemImage: "wand.and.stars")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || isGenerating)

            if isGenerating {
                Button(role: .cancel) { genTask?.cancel() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var generateButtonTitle: String {
        if isGenerating { return "Genereren…" }
        return result == nil ? "Genereer playlist" : "Opnieuw genereren"
    }

    // MARK: States

    private var idleState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 34))
                .foregroundStyle(Color.roonGold.opacity(0.7))
            Text("Beschrijf wat je wilt horen")
                .font(.headline)
            Text("RoonSage analyseert je verzoek, kiest passende tracks uit jouw bibliotheek en stelt een gevarieerde playlist samen — die je daarna kunt bijschaven.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
    }

    private var loadingState: some View {
        SkeletonRows(count: min(targetCount, 8))
            .transition(.opacity)
    }

    // MARK: Result

    @ViewBuilder
    private func resultSection(_ r: RoonClient.GenerationResult) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: Spacing.md) {
            resultHeader(r)
            FilterChips(filters: r.filters, poolSize: r.poolSize)
            saveRow
            if let qobuzStatus {
                Text(qobuzStatus).font(.caption).foregroundStyle(.secondary)
            }
            playRow
            trackList
        }
    }

    private func resultHeader(_ r: RoonClient.GenerationResult) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Color.roonGold)
                .symbolEffect(.bounce, value: tracks.count)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlistName.isEmpty ? r.title : playlistName)
                    .font(.title3.bold())
                if let desc = r.description, !desc.isEmpty {
                    Text(desc)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 5) {
                    Text("\(tracks.count) tracks")
                    if justSaved { Text("· opgeslagen").foregroundStyle(Color.roonGold) }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                if !r.aiCurated {
                    Label("Automatisch samengesteld — de AI-selectie lukte niet helemaal.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(Color.roonWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = r.droppedNote {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.roonWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
    }

    private var saveRow: some View {
        HStack(spacing: Spacing.sm) {
            TextField("Naam playlist", text: $playlistName)
                .textFieldStyle(.roundedBorder)
            Button {
                save()
            } label: {
                Label(justSaved ? "Bewaard!" : "Bewaar", systemImage: justSaved ? "checkmark" : "square.and.arrow.down")
            }
            .disabled(playlistName.trimmingCharacters(in: .whitespaces).isEmpty || tracks.isEmpty)

            if client.qobuzConfigured {
                Button { saveToQobuz() } label: {
                    Label("Qobuz", systemImage: "cloud")
                }
                .disabled(playlistName.trimmingCharacters(in: .whitespaces).isEmpty || tracks.isEmpty)
                .help("Bewaar deze playlist ook in je Qobuz-account")
            }
        }
    }

    private var playRow: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                guard let z = client.selectedZone?.id else { return }
                Haptics.tap()
                Task { await client.curateTracks(tracks, zoneID: z) }
            } label: {
                Label("Speel alles", systemImage: "play.fill").frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(client.selectedZone == nil || tracks.isEmpty)

            if client.selectedZone == nil {
                Text("Kies een zone om af te spelen")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var trackList: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                AIResultRow(index: i + 1, title: t.title, subtitle: subtitle(t), imageKey: t.imageKey) {
                    Button { playOne(t) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless)
                        .disabled(client.selectedZone == nil)
                        .accessibilityLabel("Speel \(t.title)")
                }
                .contextMenu {
                    Button { playOne(t) } label: { Label("Speel nu", systemImage: "play.fill") }
                        .disabled(client.selectedZone == nil)
                    Button { queueOne(t, next: true) } label: {
                        Label("Speel hierna", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .disabled(client.selectedZone == nil)
                    Divider()
                    Button { move(t, by: -1) } label: { Label("Omhoog", systemImage: "arrow.up") }
                        .disabled(i == 0)
                    Button { move(t, by: 1) } label: { Label("Omlaag", systemImage: "arrow.down") }
                        .disabled(i == tracks.count - 1)
                    Divider()
                    Button(role: .destructive) { remove(t) } label: {
                        Label("Verwijder uit playlist", systemImage: "trash")
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                Divider().opacity(0.4)
            }
        }
    }

    private func subtitle(_ t: TrackRecord) -> String {
        var s = t.artist ?? ""
        if let y = t.year { s += s.isEmpty ? "\(y)" : " · \(y)" }
        return s
    }

    // MARK: Actions

    private func startGenerate() {
        genTask?.cancel()
        genToken &+= 1
        let token = genToken
        genTask = Task { await generate(token: token) }
    }

    private func generate(token: Int) async {
        let request = prompt.trimmingCharacters(in: .whitespaces)
        guard !request.isEmpty else { return }
        isGenerating = true
        errorMessage = nil
        justSaved = false
        qobuzStatus = nil
        phase = .analyzing
        // Keep any existing result visible during a regenerate; restore nothing on
        // Stop. The token guard stops a superseded run from clobbering newer state.
        defer { if token == genToken { isGenerating = false; phase = nil } }

        do {
            let r = try await client.generatePlaylist(request: request, target: targetCount) { p in
                guard token == genToken else { return }
                withAnimation(Motion.quick) { phase = p }
            }
            guard !Task.isCancelled, token == genToken else { return }
            result = r
            playlistName = r.title
            withAnimation(Motion.spring) { tracks = r.tracks }
            Haptics.success()
        } catch {
            if Task.isCancelled || token != genToken { return }
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    private func save() {
        let name = playlistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !tracks.isEmpty else { return }
        client.savePlaylist(name: name, tracks: tracks)
        Haptics.success()
        flashSaved()
    }

    private func flashSaved() {
        justSaved = true
        savedTask?.cancel()
        savedTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            justSaved = false
        }
    }

    private func saveToQobuz() {
        let name = playlistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !tracks.isEmpty else { return }
        qobuzStatus = "Bewaren in Qobuz…"
        Task {
            if let r = await client.saveToQobuz(name: name, tracks: tracks) {
                qobuzStatus = "Bewaard in Qobuz — \(r.matched)/\(r.total) tracks gematcht."
            } else {
                qobuzStatus = "Bewaren in Qobuz mislukt — controleer je account in Instellingen."
            }
        }
    }

    private func playOne(_ t: TrackRecord) {
        guard let z = client.selectedZone?.id else { return }
        Haptics.tap()
        Task { await client.curateTracks([t], zoneID: z) }
    }

    private func queueOne(_ t: TrackRecord, next: Bool) {
        guard let z = client.selectedZone?.id else { return }
        Haptics.tap()
        Task { await client.queueTracks([t], next: next, zoneID: z) }
    }

    private func remove(_ t: TrackRecord) {
        withAnimation(Motion.quick) { tracks.removeAll { $0.id == t.id } }
        Haptics.tap()
    }

    private func move(_ t: TrackRecord, by delta: Int) {
        guard let i = tracks.firstIndex(where: { $0.id == t.id }) else { return }
        let j = i + delta
        guard tracks.indices.contains(j) else { return }
        withAnimation(Motion.quick) { tracks.swapAt(i, j) }
        Haptics.tap()
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
