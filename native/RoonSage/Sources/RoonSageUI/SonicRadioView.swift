import RoonSageCore
import SwiftUI

/// Daily "for you" stations seeded from the artists you play most. Each card
/// starts an endless sonic radio that refills itself as it drains.
@MainActor
public struct SonicRadioView: View {
    @Environment(RoonClient.self) private var client
    @State private var category: RoonClient.RadioCategory = .artist
    @State private var radios: [RoonClient.SonicRadio] = []
    @State private var isLoading = false
    @State private var loaded = false

    // Smart-radio tuner (the "dial").
    @State private var adventurousness: Double = RoonClient.defaultAdventurousness
    @State private var hardBan = false

    // AI artist radios → Qobuz
    @State private var qobuzRadios: [RoonClient.SonicRadioPlaylist] = []
    @State private var isLoadingQobuz = false
    @State private var qobuzLoaded = false
    @State private var isSyncing = false
    @State private var syncMessage: String?
    @State private var detailPlaylist: RoonClient.SonicRadioPlaylist?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.md)]

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if let radio = client.activeRadio { activeBanner(radio) }

                header

                adventurousnessTuner

                categoryPicker

                if !radios.isEmpty {
                    LazyVGrid(columns: columns, spacing: Spacing.md) {
                        ForEach(radios) { radioCard($0) }
                    }
                } else if isLoading {
                    SkeletonRows()
                } else if loaded {
                    emptyState
                }

                Divider().padding(.vertical, Spacing.sm)

                qobuzSection
            }
            .padding(Spacing.lg)
        }
        .navigationTitle("Radio's")
        .toolbar {
            Button {
                Task { await load(force: true); await loadQobuz(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Ververs de radio's van vandaag")
        }
        .task { await load(force: false) }
        .task { await loadQobuz(force: false) }
        .onAppear {
            adventurousness = client.radioAdventurousness
            hardBan = client.radioHardBanDisliked
        }
        .onChange(of: category) {
            // Only the daily radios above follow the picker; the Qobuz section shows
            // the full mirror across all categories, so it isn't reloaded here.
            Task { await load(force: true) }
        }
        .sheet(item: $detailPlaylist) { playlistDetailSheet($0) }
    }

    /// Switches both sections between Artiest · Genre · Sfeer · Activiteit · Decennium.
    private var categoryPicker: some View {
        Picker("Categorie", selection: $category) {
            ForEach(RoonClient.RadioCategory.allCases) { c in
                Text(c.label).tag(c)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label {
                Text("Sonische radio's").font(.headline)
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Color.roonGold)
            }
            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var headerSubtitle: String {
        switch category {
        case .artist:   return "Elke dag verse, eindeloze stations rond de artiesten die je het meest luistert."
        case .genre:    return "Eindeloze stations per genre uit je bibliotheek."
        case .mood:     return "Eindeloze stations per sfeer — gekozen op de stemming van je muziek."
        case .activity: return "Eindeloze stations voor wat je aan het doen bent: workout, focus, chillen en meer."
        case .decade:   return "Eindeloze stations per decennium, op basis van het releasejaar."
        case .sonic:    return "Sonische buurten — clusters die je bibliotheek zelf vormt, puur op hoe de muziek klinkt."
        }
    }

    /// The "dial" that turns every station from a cosy deep-cut hour into a
    /// voyage — biases the engine toward novelty/diversity and (optionally) hides
    /// thumbed-down tracks entirely. Applies to the next station you start.
    private var adventurousnessTuner: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Label("Avontuurlijkheid", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(adventureLabel).font(.caption).foregroundStyle(Color.roonGold)
            }
            Slider(value: $adventurousness, in: 0...1, step: 0.05)
                .tint(Color.roonGold)
                .onChange(of: adventurousness) { client.radioAdventurousness = adventurousness }
            HStack {
                Text("Vertrouwd").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("Op ontdekking").font(.caption2).foregroundStyle(.tertiary)
            }
            Toggle(isOn: $hardBan) {
                Text("Verberg tracks met duim-omlaag volledig").font(.caption)
            }
            .toggleStyle(.switch)
            .onChange(of: hardBan) { client.radioHardBanDisliked = hardBan }
        }
        .cardStyle()
    }

    private var adventureLabel: String {
        switch adventurousness {
        case ..<0.2:  return "Vooral bekend"
        case ..<0.45: return "Lichte verkenning"
        case ..<0.7:  return "Verkennend"
        default:      return "Op ontdekking"
        }
    }

    private func activeBanner(_ radio: RoonClient.RadioStatus) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(Color.roonGold)
            VStack(alignment: .leading, spacing: 2) {
                Text("Radio speelt").font(.caption).foregroundStyle(.secondary)
                Text(radio.artist).font(.headline)
            }
            Spacer()
            Button(role: .destructive) {
                Haptics.tap()
                client.stopRadio()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
        }
        .cardStyle()
    }

    private func radioCard(_ radio: RoonClient.SonicRadio) -> some View {
        Button {
            start(radio)
        } label: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ZStack(alignment: .bottomTrailing) {
                    AlbumArtView(imageKey: radio.imageKey, size: 150, cornerRadius: Radius.lg)
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.roonGold)
                        .shadow(radius: 3)
                        .padding(Spacing.sm)
                }
                Text(radio.artist)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("Sonische radio · \(radio.trackCount) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(client.selectedZone == nil)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.largeTitle).foregroundStyle(.tertiary)
            Text("Nog geen radio's")
                .font(.headline)
            Text("Luister wat muziek en zorg dat je bibliotheek geanalyseerd is — dan verschijnen hier dagelijks stations rond je favoriete artiesten.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xl)
    }

    // MARK: Actions

    private func start(_ radio: RoonClient.SonicRadio) {
        guard let zone = client.selectedZone else { return }
        Haptics.tap()
        Task { await client.startRadio(radio, zoneID: zone.id) }
    }

    private func load(force: Bool) async {
        guard force || !loaded else { return }
        isLoading = true
        defer { isLoading = false; loaded = true }
        radios = await client.dailyRadios(category: category)
    }

    // MARK: AI artist radios → Qobuz

    private var llmConfigured: Bool {
        let c = LLMConfigStore.load()
        return c.provider == .ollama || !c.apiKey.isEmpty
    }

    @ViewBuilder
    private var qobuzSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Label {
                        Text("AI-radio's op Qobuz").font(.headline)
                    } icon: {
                        Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.roonGold)
                    }
                    if isLoadingQobuz { ProgressView().controlSize(.small) }
                }
                Text("Alle radio's met een AI-titel + beschrijving die nu als Qobuz-playlists staan, over alle categorieën heen — continu ververst. Tik een kaart aan voor de tracklijst.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !client.qobuzConfigured {
                warningRow("Qobuz is niet ingesteld — voeg je inloggegevens toe bij Instellingen om te kunnen synchroniseren.")
            }
            if !llmConfigured {
                warningRow("Geen LLM ingesteld — radio's krijgen nette standaardtitels in plaats van AI-titels.")
            }

            HStack(spacing: Spacing.md) {
                Button {
                    Task { await sync() }
                } label: {
                    Label(isSyncing ? "Synchroniseren…" : "Sync \(category.label)-radio's naar Qobuz",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.roonGold)
                .disabled(isSyncing || !client.qobuzConfigured)

                if isSyncing { ProgressView().controlSize(.small) }
            }

            if let syncMessage {
                Text(syncMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !qobuzRadios.isEmpty {
                // Grouped by category (Artiest / Genre / …) so the full Qobuz mirror
                // is visible at once — no need to know the top category picker also
                // drove this section.
                ForEach(qobuzGroups, id: \.0) { cat, radios in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text(cat.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, spacing: Spacing.md) {
                            ForEach(radios) { qobuzCard($0) }
                        }
                    }
                }
            } else if isLoadingQobuz {
                ProgressView().frame(maxWidth: .infinity).padding(.top, Spacing.md)
            } else if qobuzLoaded {
                Text("Nog geen AI-radio's op Qobuz — zorg dat je bibliotheek geanalyseerd is en synchroniseer een selectie (Analyzer → Instellingen → Radio's).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The mirrored radios bucketed by category, in the canonical category order,
    /// skipping empties — drives the grouped Qobuz grid.
    private var qobuzGroups: [(RoonClient.RadioCategory, [RoonClient.SonicRadioPlaylist])] {
        var byCat: [RoonClient.RadioCategory: [RoonClient.SonicRadioPlaylist]] = [:]
        for r in qobuzRadios {
            let cat = RoonClient.RadioCategory(radioID: r.id) ?? .artist
            byCat[cat, default: []].append(r)
        }
        return RoonClient.RadioCategory.allCases.compactMap { cat in
            guard let rs = byCat[cat], !rs.isEmpty else { return nil }
            return (cat, rs)
        }
    }

    private func warningRow(_ text: String) -> some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.roonDanger)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.roonDanger.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.md))
    }

    private func qobuzCard(_ radio: RoonClient.SonicRadioPlaylist) -> some View {
        Button {
            Haptics.tap()
            detailPlaylist = radio
        } label: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ZStack(alignment: .topTrailing) {
                    AlbumArtView(imageKey: radio.imageKey, size: 150, cornerRadius: Radius.lg)
                    if radio.qobuzPlaylistID != nil {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.roonGold)
                            .shadow(radius: 3)
                            .padding(Spacing.sm)
                    }
                }
                Text(radio.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(radio.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text("\(radio.artist) · \(radio.tracks.count) tracks · \(radio.qobuzPlaylistID != nil ? "op Qobuz" : "nog niet gesynct")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.sm)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
            .contentShape(RoundedRectangle(cornerRadius: Radius.lg))
        }
        .buttonStyle(.plain)
    }

    /// Detail sheet: the playlist's description, status, a "play now" action, and
    /// the full numbered tracklist. (Card tracks carry no artwork, so the list is
    /// number + title + artist — clean and scannable.)
    private func playlistDetailSheet(_ pl: RoonClient.SonicRadioPlaylist) -> some View {
        NavigationStack {
            List {
                Section {
                    Text(pl.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(pl.artist) · \(pl.tracks.count) tracks · \(pl.qobuzPlaylistID != nil ? "op Qobuz" : "nog niet gesynct")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if client.selectedZone != nil {
                        Button {
                            guard let z = client.selectedZone?.id else { return }
                            Haptics.tap()
                            Task { await client.curateTracks(pl.tracks, zoneID: z) }
                            detailPlaylist = nil
                        } label: {
                            Label("Speel nu", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.roonGold)
                    }
                }
                Section("Tracks") {
                    ForEach(Array(pl.tracks.enumerated()), id: \.offset) { i, t in
                        HStack(spacing: Spacing.sm) {
                            Text("\(i + 1).")
                                .foregroundStyle(.tertiary)
                                .frame(width: 28, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.title).lineLimit(1)
                                if let a = t.artist {
                                    Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .font(.callout)
                    }
                }
            }
            .navigationTitle(pl.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("Klaar") { detailPlaylist = nil }
            }
        }
        .frame(minWidth: 440, minHeight: 540)
    }

    private func loadQobuz(force: Bool) async {
        guard force || !qobuzLoaded else { return }
        isLoadingQobuz = true
        defer { isLoadingQobuz = false; qobuzLoaded = true }
        qobuzRadios = await client.mirroredRadios()
    }

    private func sync() async {
        guard !isSyncing else { return }
        Haptics.tap()
        isSyncing = true
        syncMessage = nil
        defer { isSyncing = false }
        let count = await client.syncRadiosToQobuz(category: category)
        // Re-read the full mirror so cards reflect their new "op Qobuz" status.
        qobuzRadios = await client.mirroredRadios()
        qobuzLoaded = true
        if count > 0 {
            syncMessage = "\(count) radio('s) gesynchroniseerd naar Qobuz."
        } else if !client.qobuzConfigured {
            syncMessage = "Qobuz is niet ingesteld — vul je inloggegevens in bij Instellingen."
        } else if qobuzRadios.isEmpty {
            syncMessage = "Nog geen radio's om te synchroniseren — luister wat muziek en zorg dat je bibliotheek geanalyseerd is."
        } else {
            syncMessage = "Synchroniseren mislukt — controleer je Qobuz-instellingen."
        }
    }
}
