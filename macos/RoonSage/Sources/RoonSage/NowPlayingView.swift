import SwiftUI
import RoonSageCore

struct NowPlayingView: View {
    @Environment(RoonClient.self) private var client

    var body: some View {
        if client.zones.isEmpty {
            ContentUnavailableView("No Active Zones", systemImage: "speaker.slash",
                                   description: Text("Start playback in Roon to see zones here."))
        } else {
            List(client.zones) { zone in
                ZoneRow(zone: zone)
            }
            .navigationTitle("Now Playing")
        }
    }
}

struct ZoneRow: View {
    let zone: Zone

    var body: some View {
        HStack(spacing: 12) {
            // State indicator
            Image(systemName: zone.state.icon)
                .foregroundStyle(zone.state == .playing ? Color.accentColor : Color.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(zone.displayName).font(.headline)
                if let np = zone.nowPlaying {
                    Text(np.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if let artist = np.artist {
                        Text(artist).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                } else {
                    Text("Nothing playing").font(.subheadline).foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Volume
            if let output = zone.outputs.first, let vol = output.volume {
                HStack(spacing: 4) {
                    Image(systemName: vol.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text("\(vol.value)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
