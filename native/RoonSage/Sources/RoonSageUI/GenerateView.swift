import SwiftUI
import Observation
import RoonSageCore

// MARK: - View model

/// Owns all of GenerateView's UI + orchestration state so the view itself is pure
/// presentation. The heavy pipeline lives in `RoonClient.generatePlaylist`; this
/// model wires it to the screen: staged progress, a cancellable/token-guarded
/// run, an editable result, and saving.
@MainActor
@Observable
final class GenerateModel {
    var prompt        = ""
    var targetCount   = 20
    var isGenerating  = false
    var phase: RoonClient.GenerationPhase? = nil
    var result: RoonClient.GenerationResult? = nil
    /// Editable working copy of the curated tracks (mutated by the row actions).
    var tracks: [TrackRecord] = []
    var playlistName  = ""
    var justSaved     = false
    var qobuzStatus: String? = nil
    var errorMessage: String? = nil

    @ObservationIgnored private var genTask: Task<Void, Never>? = nil
    /// Monotonic token so a cancelled/superseded run can't reset shared state or
    /// publish a result under a newer run.
    @ObservationIgnored private var genToken = 0
    @ObservationIgnored private var savedTask: Task<Void, Never>? = nil

    var canGenerate: Bool { !prompt.trimmingCharacters(in: .whitespaces).isEmpty }
    var canSave: Bool { !playlistName.trimmingCharacters(in: .whitespaces).isEmpty && !tracks.isEmpty }

    func apply(_ t: PlaylistTemplate) {
        prompt = t.prompt
        targetCount = [10, 20, 30, 50].min(by: { abs($0 - t.trackCount) < abs($1 - t.trackCount) }) ?? 20
        playlistName = t.name
        Haptics.tap()
    }

    func startGenerate(client: RoonClient) {
        genTask?.cancel()
        genToken &+= 1
        let token = genToken
        genTask = Task { await generate(token: token, client: client) }
    }

    func stop() { genTask?.cancel() }

    private func generate(token: Int, client: RoonClient) async {
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
            let r = try await client.generatePlaylist(request: request, target: targetCount) { [weak self] p in
                guard let self, token == self.genToken else { return }
                withAnimation(Motion.quick) { self.phase = p }
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

    func save(client: RoonClient) {
        let name = playlistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !tracks.isEmpty else { return }
        client.savePlaylist(name: name, tracks: tracks)
        Haptics.success()
        justSaved = true
        savedTask?.cancel()
        savedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.justSaved = false
        }
    }

    func saveToQobuz(client: RoonClient) {
        let name = playlistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !tracks.isEmpty else { return }
        qobuzStatus = "Bewaren in Qobuz…"
        let snapshot = tracks
        Task { [weak self] in
            if let r = await client.saveToQobuz(name: name, tracks: snapshot) {
                self?.qobuzStatus = "Bewaard in Qobuz — \(r.matched)/\(r.total) tracks gematcht."
            } else {
                self?.qobuzStatus = "Bewaren in Qobuz mislukt — controleer je account in Instellingen."
            }
        }
    }

    func playAll(client: RoonClient) {
        guard let z = client.selectedZone?.id, !tracks.isEmpty else { return }
        Haptics.tap()
        let snapshot = tracks
        Task { await client.curateTracks(snapshot, zoneID: z) }
    }

    func playOne(_ track: TrackRecord, client: RoonClient) {
        guard let z = client.selectedZone?.id else { return }
        Haptics.tap()
        Task { await client.curateTracks([track], zoneID: z) }
    }

    func queueOne(_ track: TrackRecord, next: Bool, client: RoonClient) {
        guard let z = client.selectedZone?.id else { return }
        Haptics.tap()
        Task { await client.queueTracks([track], next: next, zoneID: z) }
    }

    func remove(_ track: TrackRecord) {
        withAnimation(Motion.quick) { tracks.removeAll { $0.id == track.id } }
        Haptics.tap()
    }

    func move(_ track: TrackRecord, by delta: Int) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let j = i + delta
        guard tracks.indices.contains(j) else { return }
        withAnimation(Motion.quick) { tracks.swapAt(i, j) }
        Haptics.tap()
    }
}

// MARK: - View

/// AI playlist generation. The whole analyse → candidates → curate → name
/// pipeline lives in `RoonClient.generatePlaylist` (Core); this view is pure
/// presentation over `GenerateModel`, with an *editable* result the user can
/// refine (play/queue/reorder/remove a track) before saving.
@MainActor
public struct GenerateView: View {
    public init() {}
    @Environment(RoonClient.self) private var client
    @State private var model = GenerateModel()
    @State private var showTemplates = false

    /// One featured template per category for quick access; all 63 live behind
    /// "Alle sjablonen".
    private var featured: [PlaylistTemplate] {
        PlaylistTemplates.categories.compactMap { PlaylistTemplates.inCategory($0).first }
    }

    public var body: some View {
        @Bindable var model = model
        return ScrollView {
            #if os(iOS)
            Color.clear.frame(height: 0)
            #endif
            VStack(alignment: .leading, spacing: Spacing.xl) {

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Wat voor playlist?").font(.headline)
                    AIPromptField(text: $model.prompt,
                                  placeholder: "Beschrijf de sfeer, het genre of de gelegenheid… bijv. “warme jazz voor een regenachtige zondagochtend”")
                }

                templatesSection

                HStack(spacing: Spacing.lg) {
                    HStack(spacing: Spacing.xs) {
                        Text("Tracks").foregroundStyle(.secondary)
                        Picker("Tracks", selection: $model.targetCount) {
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

                generateSection

                if let err = model.errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.roonDanger)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }

                if model.isGenerating {
                    GenerationStepper(current: model.phase ?? .analyzing)
                        .transition(.opacity)
                }

                if model.isGenerating, model.result == nil {
                    SkeletonRows(count: min(model.targetCount, 8)).transition(.opacity)
                } else if let result = model.result {
                    resultSection(result, name: $model.playlistName)
                } else {
                    idleState
                }
            }
            .padding(Spacing.xl)
            .animation(Motion.standard, value: model.result?.title)
            .animation(Motion.quick, value: model.errorMessage)
        }
        .windowWidthCapped()
        .navigationTitle("Playlist genereren")
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .sheet(isPresented: $showTemplates) {
            TemplatePicker { t in model.apply(t); showTemplates = false }
        }
    }

    // MARK: Form

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
                        Button { model.apply(t) } label: {
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

    private var generateSection: some View {
        HStack(spacing: Spacing.md) {
            Button { model.startGenerate(client: client) } label: {
                Label(generateButtonTitle, systemImage: "wand.and.stars")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canGenerate || model.isGenerating)

            if model.isGenerating {
                Button(role: .cancel) { model.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var generateButtonTitle: String {
        if model.isGenerating { return "Genereren…" }
        return model.result == nil ? "Genereer playlist" : "Opnieuw genereren"
    }

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

    // MARK: Result

    @ViewBuilder
    private func resultSection(_ r: RoonClient.GenerationResult, name: Binding<String>) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: Spacing.md) {
            resultHeader(r)
            FilterChips(filters: r.filters, poolSize: r.poolSize)
            saveRow(name)
            if let qobuzStatus = model.qobuzStatus {
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
                .symbolEffect(.bounce, value: model.tracks.count)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.playlistName.isEmpty ? r.title : model.playlistName)
                    .font(.title3.bold())
                if let desc = r.description, !desc.isEmpty {
                    Text(desc)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 5) {
                    Text("\(model.tracks.count) tracks")
                    if model.justSaved { Text("· opgeslagen").foregroundStyle(Color.roonGold) }
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

    private func saveRow(_ name: Binding<String>) -> some View {
        HStack(spacing: Spacing.sm) {
            TextField("Naam playlist", text: name)
                .textFieldStyle(.roundedBorder)
            Button { model.save(client: client) } label: {
                Label(model.justSaved ? "Bewaard!" : "Bewaar",
                      systemImage: model.justSaved ? "checkmark" : "square.and.arrow.down")
            }
            .disabled(!model.canSave)

            if client.qobuzConfigured {
                Button { model.saveToQobuz(client: client) } label: {
                    Label("Qobuz", systemImage: "cloud")
                }
                .disabled(!model.canSave)
                .help("Bewaar deze playlist ook in je Qobuz-account")
            }
        }
    }

    private var playRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Button { model.playAll(client: client) } label: {
                    Label("Speel alles", systemImage: "play.fill").frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .disabled(client.selectedZone == nil || model.tracks.isEmpty)

                // Local playback needs no zone — always offered alongside Roon.
                LocalPlayButton(style: .labeled) { model.tracks }
                    .buttonStyle(.bordered)
                    .disabled(model.tracks.isEmpty)
                Spacer(minLength: 0)
            }
            if client.selectedZone == nil {
                Text("Geen zone gekozen — “Op dit apparaat” speelt lokaal af.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Editable track list: drag-to-reorder + swipe-to-delete (List `.onMove`/
    /// `.onDelete`, scroll disabled so it sits inside the page ScrollView, like
    /// DJSetView), plus a per-row play button and a context menu (play/queue/
    /// move/remove) so reordering also works where drag isn't available.
    private var trackList: some View {
        List {
            ForEach(Array(model.tracks.enumerated()), id: \.element.id) { i, t in
                AIResultRow(index: i + 1, title: t.title, subtitle: subtitle(t), imageKey: t.imageKey) {
                    Button { model.playOne(t, client: client) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless)
                        .disabled(client.selectedZone == nil)
                        .accessibilityLabel("Speel \(t.title)")
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                .contextMenu {
                    Button { model.playOne(t, client: client) } label: { Label("Speel nu", systemImage: "play.fill") }
                        .disabled(client.selectedZone == nil)
                    Button { model.queueOne(t, next: true, client: client) } label: {
                        Label("Speel hierna", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .disabled(client.selectedZone == nil)
                    Divider()
                    Button { model.move(t, by: -1) } label: { Label("Omhoog", systemImage: "arrow.up") }
                        .disabled(i == 0)
                    Button { model.move(t, by: 1) } label: { Label("Omlaag", systemImage: "arrow.down") }
                        .disabled(i == model.tracks.count - 1)
                    Divider()
                    Button(role: .destructive) { model.remove(t) } label: {
                        Label("Verwijder uit playlist", systemImage: "trash")
                    }
                }
            }
            .onMove { from, to in model.tracks.move(fromOffsets: from, toOffset: to); Haptics.tap() }
            .onDelete { idx in model.tracks.remove(atOffsets: idx); Haptics.tap() }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .frame(minHeight: CGFloat(model.tracks.count) * 64)
    }

    private func subtitle(_ t: TrackRecord) -> String {
        var s = t.artist ?? ""
        if let y = t.year { s += s.isEmpty ? "\(y)" : " · \(y)" }
        return s
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
