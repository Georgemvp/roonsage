import SwiftUI
import RoonSageCore

struct MenuBarContent: View {
    @Environment(RoonClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Now playing in first active zone
            if let zone = client.zones.first(where: { $0.state == .playing }) {
                VStack(alignment: .leading, spacing: 2) {
                    if let np = zone.nowPlaying {
                        Text(np.title).font(.headline).lineLimit(1)
                        if let artist = np.artist {
                            Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Text(zone.displayName).font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            } else {
                Text("Nothing playing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            Divider()

            Text(client.connectionState.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .frame(width: 240)
    }
}
