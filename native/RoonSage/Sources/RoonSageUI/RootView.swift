import SwiftUI
import RoonSageCore

/// Connection gate shared by the macOS and iOS apps: shows the main interface
/// when connected to a Roon Core, otherwise the connect screen.
public struct ContentView: View {
    @Environment(RoonClient.self) private var client

    public init() {}

    public var body: some View {
        Group {
            if client.connectionState.isConnected {
                RootView()
            } else {
                ConnectView()
            }
        }
        .animation(Motion.standard, value: client.connectionState.isConnected)
        .overlay(alignment: .bottom) { ActionErrorToast() }
        .roonSageAppearance()
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
    case djSet       = "DJ Set"
    case liveDJ      = "Live DJ"
    case radios      = "Radios"
    case fingerprint = "Sonic DNA"
    case musicMap    = "Music Map"
    case songPaths   = "Song Paths"
    case alchemy     = "Song Alchemy"
    case sonicSearch = "Sonic Search"
    case discovery   = "Discovery"
    case taste        = "Taste Profile"
    case yearInReview = "Year in Review"
    case settings    = "Settings"

    public var id: String { rawValue }

    /// Weergavenaam (NL). rawValue blijft het stabiele ID; featurenamen
    /// (DJ Set, Live DJ, Sonic DNA, Music Map) blijven onvertaald.
    var title: String {
        switch self {
        case .nowPlaying:  "Nu speelt"
        case .queue:       "Wachtrij"
        case .library:     "Bibliotheek"
        case .ask:         "Vraag het"
        case .generate:    "Genereer"
        case .recommend:   "Aanbevelen"
        case .playlists:   "Playlists"
        case .djSet:       "DJ Set"
        case .liveDJ:      "Live DJ"
        case .radios:      "Radio's"
        case .fingerprint: "Sonic DNA"
        case .musicMap:    "Music Map"
        case .songPaths:   "Song Paths"
        case .alchemy:     "Song Alchemy"
        case .sonicSearch: "Sonisch zoeken"
        case .discovery:   "Ontdek"
        case .taste:       "Smaakprofiel"
        case .yearInReview: "Jaaroverzicht"
        case .settings:    "Instellingen"
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
        case .djSet:       "slider.horizontal.3"
        case .liveDJ:      "slider.horizontal.2.gobackward"
        case .radios:      "dot.radiowaves.left.and.right"
        case .fingerprint: "waveform.path.ecg"
        case .musicMap:    "map"
        case .songPaths:   "point.topleft.down.curvedto.point.bottomright.up"
        case .alchemy:     "wand.and.sparkles"
        case .sonicSearch: "sparkle.magnifyingglass"
        case .discovery:   "sparkles"
        case .taste:       "chart.radar"
        case .yearInReview: "calendar.badge.clock"
        case .settings:    "gearshape"
        }
    }
}

// MARK: - Sidebar grouping (macOS / iPad)

/// Groups the 18 destinations into scannable sections, mirroring the iOS
/// "Maak"/"Ontdek" hubs so the macOS sidebar isn't one long flat list.
enum SidebarSection: String, CaseIterable, Identifiable {
    case playback, create, explore, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playback: "Afspelen"
        case .create:   "Maak"
        case .explore:  "Ontdek"
        case .settings: "Systeem"
        }
    }

    var items: [SidebarItem] {
        switch self {
        case .playback: [.nowPlaying, .queue, .library]
        case .create:   [.ask, .generate, .recommend, .playlists, .djSet, .liveDJ]
        case .explore:  [.discovery, .radios, .fingerprint, .musicMap, .songPaths, .alchemy, .sonicSearch, .taste, .yearInReview]
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
    @State private var selection: SidebarItem = .nowPlaying
    @AppStorage("lastZoneID") private var lastZoneID: String = ""

    /// `List` selection must be optional on iOS; the rest of the view keeps a
    /// non-optional `selection` (needed by `TabView`), so bridge the two.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(get: { selection }, set: { if let v = $0 { selection = v } })
    }

    var body: some View {
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
                    .navigationTitle("Nu speelt")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { navToolbar }
            }
            .tabItem { Label("Nu speelt", systemImage: "play.circle.fill") }
            .tag(SidebarItem.nowPlaying)

            NavigationStack {
                LibraryView()
                    .navigationTitle("Bibliotheek (\(client.trackCount))")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { navToolbar }
            }
            .tabItem { Label("Bibliotheek", systemImage: "music.note.list") }
            .tag(SidebarItem.library)

            NavigationStack {
                iOSCreateHub.toolbar { navToolbar }
            }
            .tabItem { Label("Maak", systemImage: "wand.and.stars") }
            .tag(SidebarItem.generate)

            NavigationStack {
                iOSExploreHub.toolbar { navToolbar }
            }
            .tabItem { Label("Ontdek", systemImage: "sparkles") }
            .tag(SidebarItem.discovery)

            NavigationStack {
                SettingsView()
                    .navigationTitle("Instellingen")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { navToolbar }
            }
            .tabItem { Label("Instellingen", systemImage: "gearshape") }
            .tag(SidebarItem.settings)
        }
        .onChange(of: client.zones) { _, _ in
            if client.selectedZone == nil, !lastZoneID.isEmpty {
                client.selectZone(lastZoneID)
            }
        }
        .task { await autoPullFromServerIfEmpty() }
    }

    private var iOSTabSelection: Binding<SidebarItem> {
        let createItems: Set<SidebarItem> = [.generate, .ask, .recommend, .djSet, .liveDJ, .queue, .playlists]
        let exploreItems: Set<SidebarItem> = [.discovery, .radios, .fingerprint, .musicMap, .songPaths, .alchemy, .sonicSearch, .taste, .yearInReview]
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
                NavigationLink { GenerateView().navigationTitle("Genereer").navigationBarTitleDisplayMode(.inline) } label: {
                    Label("Genereer playlist", systemImage: SidebarItem.generate.icon)
                }
                NavigationLink { AskView().navigationTitle("Vraag het").navigationBarTitleDisplayMode(.inline) } label: {
                    Label("Vraag het je bibliotheek", systemImage: SidebarItem.ask.icon)
                }
                NavigationLink { RecommendView().navigationTitle("Aanbevelen").navigationBarTitleDisplayMode(.inline) } label: {
                    Label("Albums aanbevelen", systemImage: SidebarItem.recommend.icon)
                }
            }
            Section("DJ") {
                NavigationLink { DJSetView().navigationTitle("DJ Set").navigationBarTitleDisplayMode(.inline) } label: {
                    Label("DJ Set", systemImage: SidebarItem.djSet.icon)
                }
                NavigationLink { LiveDJView().navigationTitle("Live DJ").navigationBarTitleDisplayMode(.inline) } label: {
                    Label("Live DJ", systemImage: SidebarItem.liveDJ.icon)
                }
            }
            Section("Afspelen") {
                NavigationLink { QueueView().navigationTitle("Wachtrij").navigationBarTitleDisplayMode(.inline) } label: {
                    Label("Wachtrij", systemImage: SidebarItem.queue.icon)
                }
                NavigationLink { PlaylistsView().navigationTitle("Playlists").navigationBarTitleDisplayMode(.inline) } label: {
                    Label("Bewaarde playlists", systemImage: SidebarItem.playlists.icon)
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
                NavigationLink { DiscoveryView().navigationTitle("Ontdek").navigationBarTitleDisplayMode(.large) } label: {
                    Label("Ontdek", systemImage: SidebarItem.discovery.icon)
                }
                NavigationLink { SonicRadioView().navigationTitle("Radio's").navigationBarTitleDisplayMode(.large) } label: {
                    Label("Radio's", systemImage: SidebarItem.radios.icon)
                }
                NavigationLink { TasteProfileView().navigationTitle("Smaakprofiel").navigationBarTitleDisplayMode(.large) } label: {
                    Label("Smaakprofiel", systemImage: SidebarItem.taste.icon)
                }
            }
            Section("Sonic-tools") {
                NavigationLink { SonicFingerprintView().navigationTitle("Sonic DNA").navigationBarTitleDisplayMode(.large) } label: {
                    Label("Sonic DNA", systemImage: SidebarItem.fingerprint.icon)
                }
                NavigationLink { MusicMapView().navigationTitle("Music Map").navigationBarTitleDisplayMode(.large) } label: {
                    Label("Music Map", systemImage: SidebarItem.musicMap.icon)
                }
                NavigationLink { SongPathsView().navigationTitle("Song Paths").navigationBarTitleDisplayMode(.large) } label: {
                    Label("Song Paths", systemImage: SidebarItem.songPaths.icon)
                }
                NavigationLink { SongAlchemyView().navigationTitle("Song Alchemy").navigationBarTitleDisplayMode(.large) } label: {
                    Label("Song Alchemy", systemImage: SidebarItem.alchemy.icon)
                }
                NavigationLink { SonicSearchView().navigationTitle("Sonisch zoeken").navigationBarTitleDisplayMode(.large) } label: {
                    Label("Sonisch zoeken", systemImage: SidebarItem.sonicSearch.icon)
                }
                NavigationLink { YearInReviewView().navigationTitle("Jaaroverzicht").navigationBarTitleDisplayMode(.large) } label: {
                    Label("Jaaroverzicht", systemImage: SidebarItem.yearInReview.icon)
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
        case .generate:    GenerateView()
        case .recommend:   RecommendView()
        case .playlists:   PlaylistsView()
        case .djSet:       DJSetView()
        case .liveDJ:      LiveDJView()
        case .fingerprint: SonicFingerprintView()
        case .musicMap:    MusicMapView()
        case .songPaths:   SongPathsView()
        case .alchemy:     SongAlchemyView()
        case .sonicSearch: SonicSearchView()
        case .discovery:   DiscoveryView()
        case .radios:      SonicRadioView()
        case .taste:       TasteProfileView()
        case .yearInReview: YearInReviewView()
        case .settings:    SettingsView()
        }
    }

    private var connectedBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.roonSuccess).frame(width: 8, height: 8)
            Text(client.connectionState.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
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
        if let zone = client.selectedZone {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await client.previous(zoneID: zone.id) }
                } label: { Image(systemName: "backward.fill") }
                    .accessibilityLabel("Vorige track")

                Button {
                    Task { await client.playPause(zoneID: zone.id) }
                } label: { Image(systemName: zone.state == .playing ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(zone.state == .playing ? "Pauzeer" : "Speel af")

                Button {
                    Task { await client.next(zoneID: zone.id) }
                } label: { Image(systemName: "forward.fill") }
                    .accessibilityLabel("Volgende track")
            }
        }
    }

    /// Zone selector: a Menu that clearly shows the active zone (speaker symbol +
    /// name + chevron) instead of an unlabeled control, and lets you switch.
    private var zonePicker: some View {
        let active = client.selectedZone
        return Menu {
            ForEach(client.zones) { zone in
                Button {
                    client.selectZone(zone.id); lastZoneID = zone.id
                } label: {
                    Label(zone.displayName,
                          systemImage: zone.id == active?.id ? "checkmark"
                              : (zone.state == .playing ? "speaker.wave.2.fill" : "hifi.speaker"))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: active?.state == .playing ? "speaker.wave.2.fill" : "hifi.speaker")
                Text(active?.displayName ?? "Kies zone")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.7)
            }
            .font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel("Zone: \(active?.displayName ?? "geen")")
    }
}
