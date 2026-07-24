import SwiftUI
import RoonSageCore

/// Connection gate shared by the macOS and iOS apps: shows the main interface
/// when connected to a Roon Core, otherwise the connect screen.
@MainActor
public struct ContentView: View {
    @Environment(RoonClient.self) private var client
    @State private var ambient = AmbientTheme()
    @State private var sleepTimer = SleepTimer()

    public init() {}

    public var body: some View {
        Group {
            // Stay on the main interface through transient poll blips once the
            // session is live — only a cold start or a deliberate disconnect
            // drops to the connect screen. Prevents a heavy generate stalling
            // /playback from tearing down views and losing in-flight state.
            if client.connectionState.isConnected || client.hasLiveSession {
                RootView()
                    .overlay(alignment: .top) { ReconnectingBanner() }
            } else {
                WelcomeGate()
            }
        }
        .animation(Motion.standard, value: client.connectionState.isConnected)
        .animation(Motion.standard, value: client.hasLiveSession)
        .overlay(alignment: .bottom) { ActionErrorToast() }
        .roonSageAppearance()
        .appLanguage()
        // Share the now-playing album-art tint with every tab, refreshed whenever
        // the current track's artwork changes.
        .environment(ambient)
        .environment(sleepTimer)
        .task(id: client.selectedZone?.nowPlaying?.imageKey) { await ambient.update(from: client) }
    }
}

// MARK: - Welcome gate (first run)

/// Decides what a disconnected user sees:
///   - never connected before (`savedHost == nil`) → the `OnboardingView`
///     walkthrough, until they tap through to connect;
///   - already connected once, or mid-session after tapping "Verbinden" →
///     the `ConnectView` (discover / reconnect / manual entry).
///
/// Because `savedHost` is only persisted on a *successful* connect, a brand-new
/// user keeps seeing the welcome on every launch until they're actually
/// connected — then never again.
@MainActor
struct WelcomeGate: View {
    @Environment(RoonClient.self) private var client
    @State private var showConnect = false

    var body: some View {
        if client.savedHost != nil || showConnect {
            ConnectView()
                .transition(.opacity)
        } else {
            OnboardingView { withAnimation(Motion.standard) { showConnect = true } }
                .transition(.opacity)
        }
    }
}

// MARK: - Reconnecting banner

/// Thin top banner shown while the session is live but a poll blip has us
/// momentarily off `.connected`. Keeps the user informed without dropping the
/// whole UI to the connect screen (and discarding in-flight state).
@MainActor
struct ReconnectingBanner: View {
    @Environment(RoonClient.self) private var client

    var body: some View {
        // Only while genuinely establishing the first connection — once a live
        // session exists a poll blip must NOT drop a "Verbinden met …" pill over
        // the nav title (it was covering it and never clearing). Real failures
        // still surface via the bottom ActionErrorToast.
        if !client.connectionState.isConnected && !client.hasLiveSession {
            Label(client.connectionState.label, systemImage: "arrow.clockwise")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Action-error toast

/// Transient bottom toast for failed user actions (play/seek/volume/curate).
/// Driven by `RoonClient.lastActionError`; auto-dismisses after 4 seconds.
@MainActor
struct ActionErrorToast: View {
    @Environment(RoonClient.self) private var client
    @State private var visible = false
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            if visible, let err = client.lastActionError {
                Label(err.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .lineLimit(2)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.md)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.lg))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lg)
                            .strokeBorder(Color.roonDanger.opacity(0.5))
                    )
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(Motion.standard, value: visible)
        .onChange(of: client.lastActionError) { _, err in
            guard err != nil else { return }
            visible = true
            dismissTask?.cancel()
            dismissTask = Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                visible = false
            }
        }
    }
}

// MARK: - Sidebar / tab destinations

public enum SidebarItem: String, CaseIterable, Identifiable {
    case nowPlaying  = "Now Playing"
    case queue       = "Queue"
    case library     = "Library"
    case ask         = "Vraag het"
    case generate    = "Generate"
    case recommend   = "Recommend"
    case playlists   = "Playlists"
    case bookmarks   = "Bookmarks"
    case djSet       = "DJ Set"
    case liveDJ      = "Live DJ"
    case djModes     = "DJ Modes"
    case dj          = "DJ"
    case stationsHub = "Stations"
    case radios      = "Radios"
    case journeys    = "Sonic Journeys"
    case fingerprint = "Sonic DNA"
    case musicMap    = "Music Map"
    case songPaths   = "Song Paths"
    case alchemy     = "Song Alchemy"
    case sonicSearch = "Sonic Search"
    case sonicLab    = "Sonic Lab"
    case multitag    = "Multitag"
    case discover    = "Discoveries"   // outward-facing recommendation engine ("Ontdekkingen")
    case discovery   = "Discovery"     // inward editorial "Listen Now" (library stats)
    case recent       = "Recent"
    case taste        = "Taste Profile"
    case tasteHub     = "Taste"
    case yearInReview = "Year in Review"
    case settings    = "Settings"

    public var id: String { rawValue }

    /// Weergavenaam (NL). rawValue blijft het stabiele ID; featurenamen
    /// (DJ Set, Live DJ, Sonic DNA, Music Map) blijven onvertaald.
    var title: String {
        switch self {
        case .nowPlaying:  LS("nav.nowPlaying")
        case .queue:       LS("nav.queue")
        case .library:     LS("nav.library")
        case .ask:         LS("nav.ask")
        case .generate:    LS("nav.generate")
        case .recommend:   LS("nav.recommend")
        case .playlists:   LS("nav.playlists")
        case .bookmarks:   LS("nav.bookmarks")
        case .djSet:       LS("nav.djSet")
        case .liveDJ:      LS("nav.liveDJ")
        case .djModes:     LS("nav.djModes")
        case .dj:          LS("nav.dj")
        case .stationsHub: LS("nav.stationsHub")
        case .radios:      LS("nav.radios")
        case .journeys:    LS("nav.journeys")
        case .fingerprint: LS("nav.fingerprint")
        case .musicMap:    LS("nav.musicMap")
        case .songPaths:   LS("nav.songPaths")
        case .alchemy:     LS("nav.alchemy")
        case .sonicSearch: LS("nav.sonicSearch")
        case .sonicLab:    LS("nav.sonicLab")
        case .multitag:    LS("nav.multitag")
        case .discover:    LS("nav.discover")   // outward: music you don't own yet
        case .discovery:   LS("nav.discovery")
        case .recent:      LS("nav.recent")
        case .taste:       LS("nav.taste")
        case .tasteHub:    LS("nav.tasteHub")
        case .yearInReview: LS("nav.yearInReview")
        case .settings:    LS("nav.settings")
        }
    }

    var icon: String {
        switch self {
        case .nowPlaying:  "play.circle.fill"
        case .queue:       "list.number"
        case .library:     "music.note.list"
        case .ask:         "text.magnifyingglass"
        case .generate:    "wand.and.stars"
        case .recommend:   "sparkles.rectangle.stack"
        case .playlists:   "list.star"
        case .bookmarks:   "bookmark"
        case .djSet:       "slider.horizontal.3"
        case .liveDJ:      "slider.horizontal.2.gobackward"
        case .djModes:     "person.wave.2"
        case .dj:          "headphones"
        case .stationsHub: "antenna.radiowaves.left.and.right"
        case .radios:      "dot.radiowaves.left.and.right"
        case .journeys:    "map"
        case .fingerprint: "waveform.path.ecg"
        case .musicMap:    "map"
        case .songPaths:   "point.topleft.down.curvedto.point.bottomright.up"
        case .alchemy:     "wand.and.sparkles"
        case .sonicSearch: "sparkle.magnifyingglass"
        case .sonicLab:    "atom"
        case .multitag:    "tag"
        case .discover:    "wand.and.stars.inverse"
        case .discovery:   "sparkles"
        case .recent:      "clock.arrow.circlepath"
        case .taste:       "chart.radar"
        case .tasteHub:    "person.crop.circle"
        case .yearInReview: "calendar.badge.clock"
        case .settings:    "gearshape"
        }
    }
}

// MARK: - Cross-view navigation

/// Lets a deep view (e.g. an empty state) jump the sidebar/tab selection to
/// another destination — so "Genereer een playlist" from the Playlists empty
/// state actually takes the user to Generate instead of being a dead end.
public struct NavigateAction {
    let action: (SidebarItem) -> Void
    public func callAsFunction(_ item: SidebarItem) { action(item) }
}

private struct NavigateActionKey: EnvironmentKey {
    static let defaultValue = NavigateAction { _ in }
}

extension EnvironmentValues {
    public var navigateTo: NavigateAction {
        get { self[NavigateActionKey.self] }
        set { self[NavigateActionKey.self] = newValue }
    }
}

// MARK: - Sidebar grouping (macOS / iPad)

/// Groups the destinations into scannable, intent-based sections (Play /
/// Create / Stations / Explore / You), mirroring the iOS "Maak"/"Ontdek"
/// hubs so the macOS sidebar isn't one long flat list.
enum SidebarSection: String, CaseIterable, Identifiable {
    case playback, create, stations, explore, you, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playback: LS("section.playback")
        case .create:   LS("section.create")
        case .stations: LS("section.stations")
        case .explore:  LS("section.explore")
        case .you:      LS("section.you")
        case .settings: LS("section.settings")
        }
    }

    var items: [SidebarItem] {
        switch self {
        // Grouped by user intent, not by underlying engine:
        //   Play      — what's on now / your collection
        //   Create    — make a playlist from an idea
        //   Stations  — self-driving / mixing playback (all share RadioEngine or the harmonic mixer)
        //   Explore   — discover new music + navigate the sonic space of what you own
        //   You       — your taste, history and yearly recap
        case .playback: [.nowPlaying, .queue, .library, .bookmarks]
        case .create:   [.generate, .playlists]
        case .stations: [.stationsHub, .dj]
        case .explore:  [.discover, .discovery, .sonicLab, .musicMap, .multitag]
        case .you:      [.tasteHub]
        case .settings: [.settings]
        }
    }
}

// MARK: - Adaptive root

/// Adaptive navigation shell shared across platforms:
///   - regular width (macOS, iPad)  → `NavigationSplitView` with a sidebar
///   - compact width (iPhone)        → `TabView` (system shows a "More" tab past 5)
@MainActor
struct RootView: View {
    @Environment(RoonClient.self) private var client
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Environment(SleepTimer.self) private var sleepTimer
    @State private var selection: SidebarItem = .nowPlaying
    @State private var showPalette = false
    @State private var showShortcuts = false
    @AppStorage("lastZoneID") private var lastZoneID: String = ""

    /// `List` selection must be optional on iOS; the rest of the view keeps a
    /// non-optional `selection` (needed by `TabView`), so bridge the two.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(get: { selection }, set: { if let v = $0 { selection = v } })
    }

    var body: some View {
        platformShell
            // The tappable now-playing mini-bar (local + zone) is attached
            // per-tab / to the split detail below, so it sits ABOVE the tab
            // buttons instead of floating over them.
            // Cmd/Ctrl+K opens the command palette from anywhere in the app.
            .background {
                Button("") { showPalette.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .sheet(isPresented: $showPalette) {
                paletteSheet
            }
            .sheet(isPresented: $showShortcuts) { ShortcutsCheatSheet() }
    }

    @ViewBuilder
    private var paletteSheet: some View {
        let palette = CommandPaletteView(
            navigate: { selection = $0; showPalette = false },
            showShortcuts: { showShortcuts = true }
        )
        #if os(iOS)
        palette.presentationDetents([.large])
        #else
        palette
        #endif
    }

    @ViewBuilder
    private var platformShell: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            tabView
        } else {
            splitView
        }
        #else
        splitView
        #endif
    }

    // MARK: Split (macOS / iPad)

    private var splitView: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(SidebarSection.allCases) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            Label(item.title, systemImage: item.icon)
                                .tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)

            Divider()
            connectedBadge
        } detail: {
            detailView(for: selection)
                .ambientSurface()
                // Mini-bar above the window bottom — hidden on Now Playing,
                // which already hosts the full hero + transport. Placed inside
                // the navigateTo environment so its tap can switch tabs.
                .nowPlayingBarInset(hidden: selection == .nowPlaying)
                .environment(\.navigateTo, NavigateAction { selection = $0 })
                // Give the detail column a fresh identity per sidebar item so a
                // change in `selection` tears down the detail's implicit
                // navigation stack. Without this, once a NavigationLink push is
                // active (e.g. Herontdek → "Ontdek Wekelijks"), switching the
                // sidebar updates `selection` but the pushed view stays on top —
                // the detail appears frozen and other views "do nothing".
                .id(selection)
        }
        .navigationTitle("")
        .toolbar { navToolbar }
        .background { tabShortcuts }
        .onChange(of: client.zones) { _, zones in
            // Restore the last-used zone once zones are available.
            if client.selectedZone == nil, !lastZoneID.isEmpty {
                client.selectZone(lastZoneID)
            }
        }
        .task { await autoPullFromServerIfEmpty() }
    }

    /// First-run convenience: when the local library is still empty, pull
    /// everything (settings + library + analyses) from the central server once,
    /// so a fresh client configures itself without manual steps. Existing data
    /// is left untouched — refreshing later is manual via Settings → Server.
    private func autoPullFromServerIfEmpty() async {
        guard client.trackCount == 0, !client.isSyncing else { return }
        _ = await client.autoSyncEverythingFromServer()
    }

    // MARK: Tabs (iPhone) — iOS only
    // 5 primary tabs to avoid the "More" overflow. Create/Explore are hub screens
    // with NavigationLinks into the full feature set.

    #if os(iOS)
    private var tabView: some View {
        TabView(selection: iOSTabSelection) {
            NavigationStack {
                NowPlayingView()
                    // Immersive: no toolbar here. The redundant zone picker +
                    // mini-transport (useful on list screens) just compete with
                    // the hero's own zone strip and large transport, so hide the
                    // whole bar and let the artwork run to the top.
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem { Label { Text("Nu speelt") } icon: { Image(systemName: "play.circle.fill") } }
            .tag(SidebarItem.nowPlaying)

            NavigationStack {
                LibraryView()
                    .navigationTitle("Bibliotheek (\(client.trackCount))")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { navToolbar }
                    .ambientSurface()
            }
            .nowPlayingBarDocked()
            .tabItem { Label { Text("Bibliotheek") } icon: { Image(systemName: "music.note.list") } }
            .tag(SidebarItem.library)

            NavigationStack {
                iOSCreateHub.toolbar { navToolbar }.ambientSurface()
            }
            .nowPlayingBarDocked()
            .tabItem { Label { Text("Maak") } icon: { Image(systemName: "wand.and.stars") } }
            .tag(SidebarItem.generate)

            NavigationStack {
                iOSExploreHub.toolbar { navToolbar }.ambientSurface()
            }
            .nowPlayingBarDocked()
            .tabItem { Label { Text("Ontdek") } icon: { Image(systemName: "sparkles") } }
            .tag(SidebarItem.discovery)

            NavigationStack {
                SettingsView()
                    .navigationTitle("Instellingen")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { navToolbar }
                    .ambientSurface()
            }
            .nowPlayingBarDocked()
            .tabItem { Label { Text("Instellingen") } icon: { Image(systemName: "gearshape") } }
            .tag(SidebarItem.settings)
        }
        .onChange(of: client.zones) { _, _ in
            if client.selectedZone == nil, !lastZoneID.isEmpty {
                client.selectZone(lastZoneID)
            }
        }
        .environment(\.navigateTo, NavigateAction { selection = $0 })
        .task { await autoPullFromServerIfEmpty() }
    }

    private var iOSTabSelection: Binding<SidebarItem> {
        let createItems: Set<SidebarItem> = [.generate, .ask, .recommend, .queue, .playlists, .bookmarks]
        let exploreItems: Set<SidebarItem> = [.discover, .discovery, .radios, .stationsHub, .dj, .djModes, .journeys, .djSet, .liveDJ, .recent, .fingerprint, .musicMap, .songPaths, .alchemy, .sonicSearch, .sonicLab, .multitag, .taste, .tasteHub, .yearInReview]
        return Binding(
            get: {
                if createItems.contains(selection) { return .generate }
                if exploreItems.contains(selection) { return .discovery }
                return selection
            },
            set: { selection = $0 }
        )
    }

    @ViewBuilder
    private var iOSCreateHub: some View {
        List {
            Section("AI-curatie") {
                NavigationLink { CreateHubView().navigationTitle("Maak").navigationBarTitleDisplayMode(.inline) } label: {
                    Label("Maak (genereer · snel · albums)", systemImage: SidebarItem.generate.icon)
                }
            }
            Section("Afspelen") {
                NavigationLink { QueueView().navigationTitle("Wachtrij").navigationBarTitleDisplayMode(.inline) } label: {
                    Label("Wachtrij", systemImage: SidebarItem.queue.icon)
                }
                NavigationLink { PlaylistsView().navigationTitle("Playlists").navigationBarTitleDisplayMode(.inline) } label: {
                    Label("Bewaarde playlists", systemImage: SidebarItem.playlists.icon)
                }
                NavigationLink { BookmarksView() } label: {
                    Label("Bewaard voor later", systemImage: SidebarItem.bookmarks.icon)
                }
            }
        }
        .navigationTitle("Maak")
        .navigationBarTitleDisplayMode(.large)
    }

    @ViewBuilder
    private var iOSExploreHub: some View {
        List {
            Section("Ontdekken") {
                NavigationLink { DiscoverWeeklyView().navigationBarTitleDisplayMode(.large) } label: {
                    Label("Ontdek Wekelijks", systemImage: "sparkles")
                }
                NavigationLink { DiscoverFeedView().navigationTitle("Nieuw voor jou").navigationBarTitleDisplayMode(.large) } label: {
                    Label("Nieuw voor jou", systemImage: SidebarItem.discover.icon)
                }
                NavigationLink { DiscoveryView().navigationTitle("Herontdek").navigationBarTitleDisplayMode(.large) } label: {
                    Label("Herontdek", systemImage: SidebarItem.discovery.icon)
                }
            }
            Section("Stations") {
                NavigationLink { StationsHubView().navigationTitle("Stations").navigationBarTitleDisplayMode(.large) } label: {
                    Label("Stations (radio's · DJ-modi · journeys)", systemImage: SidebarItem.stationsHub.icon)
                }
                NavigationLink { DJView().navigationTitle("DJ").navigationBarTitleDisplayMode(.large) } label: {
                    Label("DJ (set · live)", systemImage: SidebarItem.dj.icon)
                }
            }
            Section("Sonic-tools") {
                NavigationLink { SonicLabView().navigationTitle("Sonic Lab").navigationBarTitleDisplayMode(.large) } label: {
                    Label("Sonic Lab", systemImage: SidebarItem.sonicLab.icon)
                }
                NavigationLink { MusicMapView().navigationTitle("Music Map").navigationBarTitleDisplayMode(.large) } label: {
                    Label("Music Map", systemImage: SidebarItem.musicMap.icon)
                }
                NavigationLink { MultitagView() } label: {
                    Label("Multitag", systemImage: SidebarItem.multitag.icon)
                }
            }
            Section("Jouw smaak") {
                NavigationLink { TasteHubView().navigationTitle("Smaak").navigationBarTitleDisplayMode(.large) } label: {
                    Label("Smaak (DNA · profiel · historie · jaar)", systemImage: SidebarItem.tasteHub.icon)
                }
            }
        }
        .navigationTitle("Ontdek")
        .navigationBarTitleDisplayMode(.large)
    }
    #endif

    // MARK: Shared destination switch

    @ViewBuilder
    private func detailView(for item: SidebarItem) -> some View {
        switch item {
        case .nowPlaying:  NowPlayingView()
        case .queue:       QueueView()
        case .library:     LibraryView()
        case .ask:         AskView()
        case .generate:    CreateHubView()
        case .recommend:   RecommendView()
        case .playlists:   PlaylistsView()
        case .bookmarks:   BookmarksView()
        case .djSet:       DJSetView()
        case .liveDJ:      LiveDJView()
        case .djModes:     DJModesView()
        case .dj:          DJView()
        case .stationsHub: StationsHubView()
        case .fingerprint: SonicFingerprintView()
        case .musicMap:    MusicMapView()
        case .songPaths:   SongPathsView()
        case .alchemy:     SongAlchemyView()
        case .sonicSearch: SonicSearchView()
        case .sonicLab:    SonicLabView()
        case .multitag:    MultitagView()
        case .discover:    DiscoverFeedView()
        case .discovery:   DiscoveryView()
        case .radios:      SonicRadioView()
        case .journeys:    SonicJourneysView()
        case .recent:      RecentView()
        case .taste:       TasteProfileView()
        case .tasteHub:    TasteHubView()
        case .yearInReview: YearInReviewView()
        case .settings:    SettingsView()
        }
    }

    private var connectedBadge: some View {
        let connected = client.connectionState.isConnected
        return HStack(spacing: 6) {
            Circle().fill(connected ? Color.roonSuccess : Color.roonDanger)
                .frame(width: 8, height: 8)
            Text(client.connectionState.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verbinding: \(client.connectionState.label)")
    }

    /// Cmd+1…9 jump straight to a destination. Hidden but active (hardware keyboard).
    private var tabShortcuts: some View {
        ZStack {
            ForEach(Array(SidebarItem.allCases.prefix(9).enumerated()), id: \.offset) { idx, item in
                Button("") { selection = item }
                    .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Toolbar (zone picker + mini transport)

    @ToolbarContentBuilder
    private var navToolbar: some ToolbarContent {
        if !client.zones.isEmpty {
            #if os(macOS)
            ToolbarItem(placement: .navigation) { zonePicker }
            #else
            ToolbarItem(placement: .topBarLeading) { zonePicker }
            #endif
        }
        if sleepTimer.isActive, let endsAt = sleepTimer.endsAt {
            ToolbarItem(placement: .automatic) {
                Button { sleepTimer.cancel() } label: {
                    Label(endsAt.formatted(date: .omitted, time: .shortened), systemImage: "moon.zzz.fill")
                        .font(.caption)
                        .foregroundStyle(Color.roonGold)
                }
                .help("Slaaptimer actief tot \(endsAt.formatted(date: .omitted, time: .shortened)) — tik om te annuleren")
            }
        }
        ToolbarItem(placement: .automatic) {
            Button { showPalette = true } label: {
                Image(systemName: "command")
            }
            .accessibilityLabel("Opdrachtenpalet")
            .help("Opdrachtenpalet (⌘K)")
        }
        if let zone = client.selectedZone {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await client.previous(zoneID: zone.id) }
                } label: { Image(systemName: "backward.fill") }
                    .accessibilityLabel("Vorige track")
                    .help("Vorige track")

                Button {
                    Task { await client.playPause(zoneID: zone.id) }
                } label: { Image(systemName: zone.state == .playing ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(zone.state == .playing ? "Pauzeer" : "Speel af")
                    .help(zone.state == .playing ? "Pauzeer" : "Speel af")

                Button {
                    Task { await client.next(zoneID: zone.id) }
                } label: { Image(systemName: "forward.fill") }
                    .accessibilityLabel("Volgende track")
                    .help("Volgende track")
            }
        }
    }

    /// Zone selector: a Menu that clearly shows the active zone (speaker symbol +
    /// name + chevron) instead of an unlabeled control, and lets you switch.
    private var zonePicker: some View {
        let localOn = client.localOutputSelected
        let active = client.selectedZone
        return Menu {
            ForEach(client.zones) { zone in
                Button {
                    client.selectZone(zone.id); lastZoneID = zone.id
                } label: {
                    Label(zone.displayName,
                          systemImage: (!localOn && zone.id == active?.id) ? "checkmark"
                              : (zone.state == .playing ? "speaker.wave.2.fill" : "hifi.speaker"))
                }
            }
            Divider()
            Button {
                client.selectLocalOutput()
            } label: {
                Label(RoonClient.localOutputName,
                      systemImage: localOn ? "checkmark" : RoonClient.localOutputIcon)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: localOn ? RoonClient.localOutputIcon
                          : (active?.state == .playing ? "speaker.wave.2.fill" : "hifi.speaker"))
                Text(localOn ? RoonClient.localOutputName : (active?.displayName ?? "Kies output"))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.7)
            }
            .font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel("Output: \(localOn ? RoonClient.localOutputName : (active?.displayName ?? "geen"))")
        .help("Kies een zone of dit apparaat")
    }
}
