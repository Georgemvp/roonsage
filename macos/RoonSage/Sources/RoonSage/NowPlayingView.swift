import SwiftUI
import RoonSageCore

struct NowPlayingView: View {
    @Environment(RoonClient.self) private var client

    var body: some View {
        if client.zones.isEmpty {
            ContentUnavailableView(
                "No Active Zones",
                systemImage: "speaker.slash",
                description: Text("Start playback in Roon to see zones here.")
            )
        } else {
            List(client.zones) { zone in
                ZoneRow(zone: zone)
            }
            .navigationTitle("Now Playing")
        }
    }
}

// MARK: - Zone row

struct ZoneRow: View {
    @Environment(RoonClient.self) private var client
    let zone: Zone

    @State private var volumeValue: Double = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Zone name + state
            HStack(spacing: 8) {
                Image(systemName: zone.state.icon)
                    .foregroundStyle(zone.state == .playing ? Color.accentColor : .secondary)
                    .frame(width: 18)
                Text(zone.displayName)
                    .font(.headline)
                Spacer()
                // Playback state badge
                if zone.state == .playing {
                    Text("PLAYING")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.accentColor)
                }
            }

            // Track info
            if let np = zone.nowPlaying {
                VStack(alignment: .leading, spacing: 2) {
                    Text(np.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    if let artist = np.artist {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let album = np.album {
                        Text(album)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text("Nothing playing")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Transport controls
            HStack(spacing: 16) {
                // Previous
                Button {
                    Task { await client.previous(zoneID: zone.id) }
                } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                // Play / Pause
                Button {
                    Task { await client.playPause(zoneID: zone.id) }
                } label: {
                    Image(systemName: zone.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                // Next
                Button {
                    Task { await client.next(zoneID: zone.id) }
                } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                Spacer()

                // Volume
                if let output = zone.outputs.first, let vol = output.volume {
                    HStack(spacing: 6) {
                        Button {
                            Task { await client.toggleMute(outputID: output.id, muted: !vol.isMuted) }
                        } label: {
                            Image(systemName: vol.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)

                        Slider(
                            value: $volumeValue,
                            in: Double(vol.min)...Double(max(vol.max, vol.min + 1)),
                            step: Double(vol.step > 0 ? vol.step : 1)
                        ) { editing in
                            if !editing {
                                Task { await client.setVolume(outputID: output.id, value: Int(volumeValue)) }
                            }
                        }
                        .frame(width: 80)
                        .onAppear { volumeValue = Double(vol.value) }
                        .onChange(of: vol.value) { _, new in volumeValue = Double(new) }

                        Text("\(vol.isMuted ? 0 : vol.value)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}
