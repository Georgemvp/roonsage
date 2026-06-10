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
        .animation(.easeInOut, value: client.connectionState.isConnected)
        .roonSageAppearance()
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
    case fingerprint = "Sonic DNA"
    case musicMap    = "Music Map"
    case discovery   = "Discovery"
    case taste        = "Taste Profile"
    case settings    = "Settings"

    public var id: String { rawValue }

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
        case .fingerprint: "waveform.path.ecg"
        case .musicMap:    "map"
        case .discovery:   "sparkles"
        case .taste:       "chart.radar"
        case .settings:    "gearshape"
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
                ForEach(SidebarItem.allCases) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .tag(item)
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
    }

    // MARK: Tabs (iPhone)

    private var tabView: some View {
        TabView(selection: $selection) {
            ForEach(SidebarItem.allCases) { item in
                NavigationStack {
                    detailView(for: item)
                        .navigationTitle(item.rawValue)
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar { navToolbar }
                }
                .tabItem { Label(item.rawValue, systemImage: item.icon) }
                .tag(item)
            }
        }
    }

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
        case .discovery:   DiscoveryView()
        case .taste:       TasteProfileView()
        case .settings:    SettingsView()
        }
    }

    private var connectedBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(.green).frame(width: 8, height: 8)
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
        if client.zones.count > 1 {
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
                    .accessibilityLabel("Previous track")

                Button {
                    Task { await client.playPause(zoneID: zone.id) }
                } label: { Image(systemName: zone.state == .playing ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(zone.state == .playing ? "Pause" : "Play")

                Button {
                    Task { await client.next(zoneID: zone.id) }
                } label: { Image(systemName: "forward.fill") }
                    .accessibilityLabel("Next track")
            }
        }
    }

    private var zonePicker: some View {
        Picker("Zone", selection: Binding(
            get: { client.selectedZone?.id ?? "" },
            set: { client.selectZone($0) }
        )) {
            ForEach(client.zones) { zone in
                Label(zone.displayName, systemImage: "hifi.speaker")
                    .tag(zone.id)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 200)
    }
}
