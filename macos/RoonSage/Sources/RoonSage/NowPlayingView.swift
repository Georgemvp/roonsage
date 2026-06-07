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
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
            .listStyle(.plain)
            .navigationTitle("Now Playing")
        }
    }
}

// MARK: - Zone row

struct ZoneRow: View {
    @Environment(RoonClient.self) private var client
    let zone: Zone

    @State private var volumeValue: Double = 50
    private var isSelected: Bool { client.selectedZone?.id == zone.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top row: art + track info + state badge
            HStack(alignment: .top, spacing: 12) {
                AlbumArtView(imageKey: zone.nowPlaying?.imageKey, size: 56)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(zone.displayName)
                            .font(.subheadline.bold())
                            .foregroundStyle(isSelected ? Color.accentColor : .primary)
                        Spacer()
                        if zone.state == .playing {
                            Label("Playing", systemImage: "waveform")
                                .labelStyle(.iconOnly)
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                                .symbolEffect(.variableColor.iterative, options: .repeating)
                        }
                    }
                    if let np = zone.nowPlaying {
                        Text(np.title)
                            .font(.body)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if let artist = np.artist {
                                Text(artist).foregroundStyle(.secondary)
                            }
                            if np.artist != nil, np.album != nil {
                                Text("·").foregroundStyle(.tertiary)
                            }
                            if let album = np.album {
                                Text(album).foregroundStyle(.tertiary)
                            }
                        }
                        .font(.caption)
                        .lineLimit(1)
                    } else {
                        Text("Nothing playing")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { client.selectZone(zone.id) }

            // Transport controls
            HStack(spacing: 0) {
                Group {
                    controlButton("backward.fill")  { Task { await client.previous(zoneID: zone.id) } }
                    playPauseButton
                    controlButton("forward.fill")   { Task { await client.next(zoneID: zone.id) } }
                }

                Spacer()

                // Volume
                if let output = zone.outputs.first, let vol = output.volume {
                    HStack(spacing: 6) {
                        Button {
                            Task { await client.toggleMute(outputID: output.id, muted: !vol.isMuted) }
                        } label: {
                            Image(systemName: vol.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        Slider(
                            value: $volumeValue,
                            in: Double(vol.min)...Double(max(vol.max, vol.min + 1)),
                            step: Double(max(vol.step, 1))
                        ) { editing in
                            if !editing {
                                Task { await client.setVolume(outputID: output.id, value: Int(volumeValue)) }
                            }
                        }
                        .frame(width: 90)
                        .onAppear { volumeValue = Double(vol.value) }
                        .onChange(of: vol.value) { _, v in volumeValue = Double(v) }

                        Text("\(vol.isMuted ? 0 : vol.value)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                    }
                }
            }
            .font(.callout)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(.windowBackgroundColor).opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.25) : Color.clear, lineWidth: 1)
                )
        )
    }

    private var playPauseButton: some View {
        Button {
            Task { await client.playPause(zoneID: zone.id) }
        } label: {
            Image(systemName: zone.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }

    private func controlButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}
