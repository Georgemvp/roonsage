import SwiftUI
import RoonSageCore

public struct NowPlayingView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    public var body: some View {
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

@MainActor
struct ZoneRow: View {
    @Environment(RoonClient.self) private var client
    let zone: Zone

    @State private var volumeValue: Double = 50
    @State private var displayPosition: Double = 0
    @State private var isSeeking = false
    @State private var feat: (bpm: Double, camelot: String, tags: [String])?
    @State private var startingRadio = false
    @State private var artColor: Color?
    private var isSelected: Bool { client.selectedZone?.id == zone.id }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top row: art + track info + state badge
            HStack(alignment: .top, spacing: 12) {
                AlbumArtView(imageKey: zone.nowPlaying?.imageKey, size: 56)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(zone.displayName)
                            .font(.subheadline.bold())
                            .foregroundStyle(isSelected ? Color.roonGold : .primary)
                        Spacer()
                        if zone.state == .playing {
                            Label("Playing", systemImage: "waveform")
                                .labelStyle(.iconOnly)
                                .font(.caption)
                                .foregroundStyle(Color.roonGold)
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

            // Track progress bar
            if let np = zone.nowPlaying, let length = np.length, length > 0 {
                VStack(spacing: 3) {
                    Slider(value: $displayPosition, in: 0...Double(length)) { editing in
                        isSeeking = editing
                        if !editing {
                            Task { await client.seek(zoneID: zone.id, seconds: displayPosition) }
                        }
                    }
                    .controlSize(.mini)
                    .tint(Color.roonGold)
                    HStack {
                        Text(formatTime(displayPosition))
                        Spacer()
                        Text(formatTime(Double(length)))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
            }

            // Audio features + Radio (when the track is analyzed)
            if let np = zone.nowPlaying, let f = feat {
                HStack(spacing: 6) {
                    if f.bpm > 0 { featBadge("\(Int(f.bpm)) BPM") }
                    if !f.camelot.isEmpty { featBadge(f.camelot) }
                    if !f.tags.isEmpty {
                        Text(f.tags.prefix(3).joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
                    Button {
                        startingRadio = true
                        Task {
                            await client.playSonicRadio(title: np.title, artist: np.artist, album: np.album, zoneID: zone.id)
                            startingRadio = false
                        }
                    } label: {
                        if startingRadio {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Sonic Radio", systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(startingRadio)
                    .help("Play a station of tracks sonically similar to this one")
                }
            }

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
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.roonGold.opacity(0.08) : Color.platformCardBackground.opacity(0.5))
                // Subtle backdrop tinted by the album art's dominant colour.
                if let artColor {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [artColor.opacity(0.30), artColor.opacity(0.04)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.roonGold.opacity(0.25) : Color.clear, lineWidth: 1)
            }
            .animation(.easeInOut(duration: 0.4), value: artColor)
        )
        .task(id: zone.nowPlaying?.imageKey) {
            guard let key = zone.nowPlaying?.imageKey,
                  let url = client.imageURL(forKey: key, size: 64) else { artColor = nil; return }
            artColor = await ImageCache.shared.dominantColor(for: url)
        }
        .onAppear { displayPosition = zone.seekPosition ?? 0; refreshFeatures() }
        .onChange(of: zone.seekPosition) { _, pos in displayPosition = pos ?? 0 }
        .onChange(of: zone.nowPlaying?.title) { _, _ in refreshFeatures() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if zone.state == .playing, !isSeeking { displayPosition += 1 }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func refreshFeatures() {
        if let np = zone.nowPlaying {
            feat = client.featuresFor(title: np.title, artist: np.artist, album: np.album)
        } else {
            feat = nil
        }
    }

    private func featBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }

    private var playPauseButton: some View {
        Button {
            Task { await client.playPause(zoneID: zone.id) }
        } label: {
            Image(systemName: zone.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.roonGold)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .accessibilityLabel(zone.state == .playing ? "Pause" : "Play")
    }

    private func controlButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .accessibilityLabel(icon.contains("backward") ? "Previous track" : "Next track")
    }
}
