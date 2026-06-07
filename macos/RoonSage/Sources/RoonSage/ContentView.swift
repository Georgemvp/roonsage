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

// MARK: - Main app navigation (shown when connected)

struct MainAppView: View {
    @Environment(RoonClient.self) private var client
    @State private var selection: SidebarItem = .nowPlaying

    enum SidebarItem: String, CaseIterable, Identifiable {
        case nowPlaying = "Now Playing"
        case library    = "Library"
        case discovery  = "Discovery"
        case taste      = "Taste Profile"
        case settings   = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .nowPlaying: "play.circle.fill"
            case .library:    "music.note.list"
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
            // Connection badge at sidebar bottom
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
            case .library:    LibraryView()
            case .discovery:  PlaceholderView(title: "Discovery", icon: "sparkles")
            case .taste:      PlaceholderView(title: "Taste Profile", icon: "chart.radar")
            case .settings:   SettingsView()
            }
        }
        .navigationTitle("")
    }
}

// MARK: - Placeholder

struct PlaceholderView: View {
    let title: String
    let icon: String
    var body: some View {
        ContentUnavailableView(title, systemImage: icon,
                               description: Text("Coming in a future phase."))
    }
}
