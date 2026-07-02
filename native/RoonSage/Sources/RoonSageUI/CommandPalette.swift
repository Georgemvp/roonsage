import SwiftUI
import RoonSageCore

// MARK: - Sleep timer

/// A one-shot sleep timer shared app-wide (injected at the root, like the
/// ambient theme). When it fires it pauses whatever is playing on this device.
/// Kept as an `@Observable` object — not view `@State` — so the countdown
/// survives navigation and the pause happens even if no view is on screen.
@MainActor
@Observable
public final class SleepTimer {
    /// When the timer will fire, or `nil` when it's off. Drives the menu-bar /
    /// palette "actief tot HH:MM" affordance.
    public private(set) var endsAt: Date?
    private var task: Task<Void, Never>?

    public init() {}

    public var isActive: Bool { endsAt != nil }

    /// Arm (or re-arm) the timer. `action` runs on the main actor when it fires.
    public func schedule(minutes: Int, action: @escaping @MainActor () async -> Void) {
        cancel()
        endsAt = Date().addingTimeInterval(Double(minutes) * 60)
        let ns = UInt64(minutes) * 60 * 1_000_000_000
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            await action()
            self?.endsAt = nil
            self?.task = nil
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        endsAt = nil
    }
}

// MARK: - Command model + fuzzy matching

/// One actionable entry in the command palette.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let icon: String
    /// Extra terms the fuzzy matcher considers besides the title.
    var keywords: [String] = []
    let group: String
    /// Tinted when the command reflects an active state (shuffle on, active theme…).
    var isActive: Bool = false
    let run: @MainActor () -> Void
}

/// Lightweight subsequence fuzzy scorer — no external dependency. Rewards
/// consecutive runs and word-start matches, lightly penalises long targets, so
/// "sr" ranks "Sonic Radio" above "Smaakprofiel".
enum PaletteFuzzy {
    static func score(_ query: String, _ text: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        guard q.count <= t.count else { return nil }
        var qi = 0, score = 0, lastMatch = -1, streak = 0
        for (ti, ch) in t.enumerated() {
            guard qi < q.count, ch == q[qi] else { continue }
            if lastMatch == ti - 1 { streak += 1; score += 5 + streak } else { streak = 0; score += 1 }
            if ti == 0 || t[ti - 1] == " " { score += 3 }   // word-start bonus
            lastMatch = ti
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score - t.count / 20
    }

    /// Best score across the title (weighted) and keywords.
    static func best(_ query: String, command c: PaletteCommand) -> Int? {
        var best = score(query, c.title).map { $0 + 4 }
        for kw in keywordsIncludingGroup(c) {
            if let s = score(query, kw) {
                best = max(best ?? Int.min, s)
            }
        }
        return best
    }

    private static func keywordsIncludingGroup(_ c: PaletteCommand) -> [String] {
        c.keywords + [c.group]
    }
}

// MARK: - Command palette

/// Cmd/Ctrl+K launcher: one fuzzy field over every navigation destination and
/// common action, plus live library search. Presented as a sheet so it works
/// identically on macOS and iOS.
@MainActor
struct CommandPaletteView: View {
    @Environment(RoonClient.self) private var client
    @Environment(SleepTimer.self) private var sleepTimer
    @Environment(\.dismiss) private var dismiss
    @AppStorage("themePreset") private var themePreset: ThemePreset = .custom
    @AppStorage("showVisualizer") private var showVisualizer = true

    let navigate: (SidebarItem) -> Void
    let showShortcuts: () -> Void

    @State private var query = ""
    @State private var trackResults: [DatabaseManager.LibraryTrackRow] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
        }
        .frame(minWidth: 420, minHeight: 460)
        .task { searchFocused = true }
        .task(id: query) { await runLibrarySearch() }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Zoek een actie of track…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { runTop() }
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Wis zoekopdracht")
            }
            Text("esc").font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(Spacing.lg)
    }

    // MARK: Results

    private var resultsList: some View {
        List {
            ForEach(groupedCommands, id: \.0) { group, commands in
                Section(group) {
                    ForEach(commands) { command in
                        Button { command.run(); dismiss() } label: { commandRow(command) }
                            .buttonStyle(.plain)
                    }
                }
            }
            if !trackResults.isEmpty {
                Section("Bibliotheek") {
                    ForEach(trackResults, id: \.id) { track in
                        Button { playTrack(track); dismiss() } label: { trackRow(track) }
                            .buttonStyle(.plain)
                    }
                }
            }
            if groupedCommands.isEmpty && trackResults.isEmpty {
                Text("Geen resultaten voor '\(query)'")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }

    private func commandRow(_ c: PaletteCommand) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: c.icon)
                .foregroundStyle(c.isActive ? Color.roonGold : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title)
                if let s = c.subtitle {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if c.isActive {
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.roonGold)
            }
        }
        .contentShape(Rectangle())
    }

    private func trackRow(_ t: DatabaseManager.LibraryTrackRow) -> some View {
        HStack(spacing: Spacing.md) {
            AlbumArtView(imageKey: t.imageKey, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).lineLimit(1)
                Text([t.artist, t.album].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "play.fill").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    // MARK: Ranking

    /// Commands filtered by the query and grouped, preserving a stable group order.
    private var groupedCommands: [(String, [PaletteCommand])] {
        let scored: [(PaletteCommand, Int)] = allCommands.compactMap { c in
            guard let s = PaletteFuzzy.best(query, command: c) else { return nil }
            return (c, s)
        }
        let order = ["Afspelen", "Nu speelt", "Navigatie", "Slaaptimer", "Thema", "Systeem"]
        var byGroup: [String: [(PaletteCommand, Int)]] = [:]
        for pair in scored { byGroup[pair.0.group, default: []].append(pair) }
        return order.compactMap { g in
            guard var items = byGroup[g], !items.isEmpty else { return nil }
            // When searching, sort by score; when browsing (empty query) keep the
            // authored order so the list reads predictably.
            if !query.isEmpty { items.sort { $0.1 > $1.1 } }
            return (g, items.map(\.0))
        }
    }

    /// Runs the single best-ranked action (Return key).
    private func runTop() {
        if !query.isEmpty,
           let top = allCommands.compactMap({ c -> (PaletteCommand, Int)? in
               PaletteFuzzy.best(query, command: c).map { (c, $0) }
           }).max(by: { $0.1 < $1.1 }) {
            top.0.run(); dismiss(); return
        }
        if let first = trackResults.first { playTrack(first); dismiss() }
    }

    // MARK: Actions

    private func playTrack(_ t: DatabaseManager.LibraryTrackRow) {
        guard let zone = client.selectedZone?.id else { return }
        Haptics.tap()
        let rec = TrackRecord(id: t.id, title: t.title, artist: t.artist, album: t.album, year: t.year, isLive: t.isLive)
        Task { await client.curateTracks([rec], zoneID: zone) }
    }

    private func runLibrarySearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { trackResults = []; return }
        try? await Task.sleep(nanoseconds: 200_000_000)   // debounce
        guard !Task.isCancelled else { return }
        trackResults = Array(await client.browseTracks(query: q, tag: nil, limit: 8).prefix(8))
    }

    // MARK: Command catalogue

    private var allCommands: [PaletteCommand] {
        var out: [PaletteCommand] = []

        // Playback / transport (needs a zone)
        if let zone = client.selectedZone {
            let playing = zone.state == .playing
            out.append(PaletteCommand(
                id: "playpause", title: playing ? "Pauzeer" : "Speel af",
                icon: playing ? "pause.fill" : "play.fill",
                keywords: ["afspelen", "pauze", "play", "pause", "speel"], group: "Afspelen",
                run: { Task { await client.playPause(zoneID: zone.id) } }))
            out.append(PaletteCommand(
                id: "next", title: "Volgende track", icon: "forward.fill",
                keywords: ["skip", "next", "verder"], group: "Afspelen",
                run: { Task { await client.next(zoneID: zone.id) } }))
            out.append(PaletteCommand(
                id: "prev", title: "Vorige track", icon: "backward.fill",
                keywords: ["previous", "terug"], group: "Afspelen",
                run: { Task { await client.previous(zoneID: zone.id) } }))
            let shuffleOn = zone.shuffle ?? false
            out.append(PaletteCommand(
                id: "shuffle", title: shuffleOn ? "Shuffle uitzetten" : "Shuffle aanzetten",
                icon: "shuffle", keywords: ["willekeurig", "shuffle"], group: "Afspelen", isActive: shuffleOn,
                run: { Task { await client.setShuffle(zoneID: zone.id, enabled: !shuffleOn) } }))
            let loop = zone.loopMode ?? "disabled"
            out.append(PaletteCommand(
                id: "repeat", title: "Herhaalmodus wisselen",
                subtitle: NowPlayingHeroOptions.loopLabel(loop),
                icon: loop == "loop_one" ? "repeat.1" : "repeat",
                keywords: ["herhaal", "loop", "repeat"], group: "Afspelen", isActive: loop != "disabled",
                run: { Task { await client.setRepeat(zoneID: zone.id, mode: NowPlayingHeroOptions.nextLoop(loop)) } }))
            if let output = zone.outputs.first {
                out.append(PaletteCommand(
                    id: "volup", title: "Volume omhoog", icon: "speaker.wave.3.fill",
                    keywords: ["harder", "volume"], group: "Afspelen",
                    run: { Task { await client.adjustVolume(outputID: output.id, delta: 4) } }))
                out.append(PaletteCommand(
                    id: "voldown", title: "Volume omlaag", icon: "speaker.wave.1.fill",
                    keywords: ["zachter", "volume"], group: "Afspelen",
                    run: { Task { await client.adjustVolume(outputID: output.id, delta: -4) } }))
            }

            // Now-playing specific
            if let np = zone.nowPlaying {
                out.append(PaletteCommand(
                    id: "like", title: "Vind ik leuk", icon: "hand.thumbsup",
                    keywords: ["like", "duim", "leuk"], group: "Nu speelt",
                    run: { Task { await client.setFeedback(.like, title: np.title, artist: np.artist, album: np.album) } }))
                out.append(PaletteCommand(
                    id: "dislike", title: "Vind ik niet leuk", icon: "hand.thumbsdown",
                    keywords: ["dislike", "niet leuk", "skip"], group: "Nu speelt",
                    run: { Task { await client.setFeedback(.dislike, title: np.title, artist: np.artist, album: np.album) } }))
                out.append(PaletteCommand(
                    id: "sonicradio", title: "Start Sonic Radio", subtitle: np.title,
                    icon: "dot.radiowaves.left.and.right",
                    keywords: ["radio", "station", "sonic"], group: "Nu speelt",
                    run: { Task { await client.playSonicRadio(title: np.title, artist: np.artist, album: np.album, zoneID: zone.id) } }))
            }
        }

        // Navigation to every destination
        for item in SidebarItem.allCases {
            out.append(PaletteCommand(
                id: "nav-\(item.id)", title: "Ga naar \(item.title)", icon: item.icon,
                keywords: [item.title, "open", "ga naar", "navigatie"], group: "Navigatie",
                run: { navigate(item) }))
        }

        // Sleep timer
        for minutes in [15, 30, 60, 120] {
            out.append(PaletteCommand(
                id: "sleep-\(minutes)", title: "Slaaptimer: \(minutes) min",
                icon: "moon.zzz", keywords: ["slaap", "timer", "sleep", "\(minutes)"], group: "Slaaptimer",
                run: { sleepTimer.schedule(minutes: minutes) { await client.pauseForSleep() } }))
        }
        if sleepTimer.isActive {
            out.append(PaletteCommand(
                id: "sleep-off", title: "Slaaptimer uitzetten", icon: "moon.zzz.fill",
                keywords: ["slaap", "annuleer", "stop"], group: "Slaaptimer", isActive: true,
                run: { sleepTimer.cancel() }))
        }

        // Theme presets
        for preset in ThemePreset.allCases {
            out.append(PaletteCommand(
                id: "theme-\(preset.id)", title: "Thema: \(preset.label)",
                icon: "paintpalette", keywords: ["thema", "kleur", preset.label], group: "Thema",
                isActive: preset == themePreset,
                run: { themePreset = preset }))
        }

        // System
        out.append(PaletteCommand(
            id: "visualizer", title: showVisualizer ? "Visualizer uitzetten" : "Visualizer aanzetten",
            icon: "waveform", keywords: ["visualizer", "equalizer", "animatie"], group: "Systeem",
            isActive: showVisualizer,
            run: { showVisualizer.toggle() }))
        out.append(PaletteCommand(
            id: "shortcuts", title: "Toon sneltoetsen", icon: "keyboard",
            keywords: ["sneltoets", "toetsen", "help", "shortcuts"], group: "Systeem",
            run: { showShortcuts() }))

        return out
    }
}

// MARK: - Keyboard shortcut cheat sheet

/// A quick reference of the app's keyboard shortcuts, opened from the palette
/// ("Toon sneltoetsen") or the Help menu.
@MainActor
struct ShortcutsCheatSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable { let id = UUID(); let keys: String; let action: String }

    private let sections: [(String, [Row])] = [
        ("Algemeen", [
            .init(keys: "⌘K", action: "Opdrachtenpalet openen"),
            .init(keys: "⌘1 – ⌘9", action: "Spring naar een onderdeel in de zijbalk"),
        ]),
        ("Afspelen", [
            .init(keys: "⌘P", action: "Afspelen / pauzeren"),
            .init(keys: "⌘]", action: "Volgende track"),
            .init(keys: "⌘[", action: "Vorige track"),
            .init(keys: "⌘↑", action: "Volume omhoog"),
            .init(keys: "⌘↓", action: "Volume omlaag"),
        ]),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.0) { title, rows in
                    Section(title) {
                        ForEach(rows) { row in
                            HStack {
                                Text(row.action)
                                Spacer()
                                Text(row.keys)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, Spacing.sm)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.sm))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sneltoetsen")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Klaar") { dismiss() }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 360)
    }
}
