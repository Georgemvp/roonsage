import SwiftUI
import RoonSageCore

struct ContentView: View {
    @Environment(RoonClient.self) private var client

    var body: some View {
        Group {
            if client.connectionState.isConnected {
                MainAppView()
            } else {
                ConnectView()
            }
        }
        .animation(.easeInOut, value: client.connectionState.isConnected)
    }
}

// MARK: - Main navigation

@MainActor
struct MainAppView: View {
    @Environment(RoonClient.self) private var client
    @State private var selection: SidebarItem = .nowPlaying

    enum SidebarItem: String, CaseIterable, Identifiable {
        case nowPlaying = "Now Playing"
        case queue      = "Queue"
        case library    = "Library"
        case generate   = "Generate"
        case recommend  = "Recommend"
        case playlists  = "Playlists"
        case djSet      = "DJ Set"
        case discovery  = "Discovery"
        case taste      = "Taste Profile"
        case settings   = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .nowPlaying: "play.circle.fill"
            case .queue:      "list.number"
            case .library:    "music.note.list"
            case .generate:   "wand.and.stars"
            case .recommend:  "sparkles.rectangle.stack"
            case .playlists:  "list.star"
            case .djSet:      "slider.horizontal.3"
            case .discovery:  "sparkles"
            case .taste:      "chart.radar"
            case .settings:   "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)

            Divider()

            // Connected core badge
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text(client.connectionState.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
        } detail: {
            switch selection {
            case .nowPlaying: NowPlayingView()
            case .queue:      QueueView()
            case .library:    LibraryView()
            case .generate:   GenerateView()
            case .recommend:  RecommendView()
            case .playlists:  PlaylistsView()
            case .djSet:      DJSetView()
            case .discovery:  DiscoveryView()
            case .taste:      TasteProfileView()
            case .settings:   SettingsView()
            }
        }
        .navigationTitle("")
        .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        // Zone picker (only when multiple zones exist)
        if client.zones.count > 1 {
            ToolbarItem(placement: .navigation) {
                Picker("Zone", selection: Binding(
                    get: { client.selectedZone?.id ?? "" },
                    set: { client.selectZone($0) }
                )) {
                    ForEach(client.zones) { zone in
                        Label(zone.displayName, systemImage: zone.state.icon)
                            .tag(zone.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
            }
        }

        // Mini transport controls in toolbar (for selected zone)
        if let zone = client.selectedZone {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await client.previous(zoneID: zone.id) }
                } label: {
                    Image(systemName: "backward.fill")
                }

                Button {
                    Task { await client.playPause(zoneID: zone.id) }
                } label: {
                    Image(systemName: zone.state == .playing ? "pause.fill" : "play.fill")
                }

                Button {
                    Task { await client.next(zoneID: zone.id) }
                } label: {
                    Image(systemName: "forward.fill")
                }
            }
        }
    }
}
