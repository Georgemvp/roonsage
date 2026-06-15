import SwiftUI
import RoonSageCore

/// Immersive Now Playing: the selected zone is the showpiece — full-bleed
/// blurred-art backdrop, large springy album art, generous scrubber and gold
/// transport — with a compact switcher strip for the other zones. The old
/// version was a uniform list of small zone cards; a music app's marquee
/// screen deserves more than a 56-pt thumbnail.
public struct NowPlayingView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    public var body: some View {
        if client.zones.isEmpty {
            ContentUnavailableView(
                "Geen actieve zones",
                systemImage: "speaker.slash",
                description: Text("Start afspelen in Roon om hier zones te zien.")
            )
        } else if let zone = client.selectedZone {
            ZStack {
                NowPlayingBackdrop(zone: zone)
                VStack(spacing: 0) {
                    if client.zones.count > 1 {
                        ZoneStrip(selectedID: zone.id)
                            .padding(.top, Spacing.sm)
                    }
                    NowPlayingHero(zone: zone)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Meaningful bar title: the playing track (or the zone when idle) —
            // not the redundant "Nu speelt" (the tab bar already labels this).
            .navigationTitle(zone.nowPlaying?.title ?? zone.displayName)
        } else {
            // Zones exist but none is selected yet (transient on launch/reconnect,
            // before RootView restores the last-used zone). Don't show a blank
            // screen — offer the zones explicitly.
            ContentUnavailableView {
                Label("Kies een zone", systemImage: "hifi.speaker")
            } description: {
                Text("Selecteer hierboven een zone om af te spelen.")
            } actions: {
                ForEach(client.zones) { zone in
                    Button {
                        client.selectZone(zone.id)
                        Haptics.tap()
                    } label: {
                        Label(zone.displayName,
                              systemImage: zone.state == .playing ? "speaker.wave.2.fill" : "hifi.speaker")
                    }
                }
            }
        }
    }
}

// MARK: - Backdrop (blurred art + scrim)

/// Full-bleed backdrop: the album art, heavily blurred and dimmed behind a
/// material so foreground text stays legible in light and dark mode, with a
/// subtle tint from the art's dominant colour. Cross-fades with the ambient
/// motion token on track change.
@MainActor
private struct NowPlayingBackdrop: View {
    @Environment(RoonClient.self) private var client
    let zone: Zone
    @State private var artColor: Color?

    var body: some View {
        ZStack {
            if let key = zone.nowPlaying?.imageKey,
               let url = client.imageURL(forKey: key, size: 300) {
                CachedArtImage(url: url) { Color.clear }
                    .id(key)
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: 60, opaque: true)
                    .transition(.opacity)
            }
            Rectangle().fill(.regularMaterial)
            if let artColor {
                LinearGradient(
                    colors: [artColor.opacity(0.35), artColor.opacity(0.05), .clear],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .animation(Motion.ambient, value: artColor)
        .task(id: zone.nowPlaying?.imageKey) {
            guard let key = zone.nowPlaying?.imageKey,
                  let url = client.imageURL(forKey: key, size: 64) else { artColor = nil; return }
            artColor = await ImageCache.shared.dominantColor(for: url)
        }
    }
}

// MARK: - Zone switcher strip

/// Compact horizontal chips for switching zones without leaving the hero.
@MainActor
private struct ZoneStrip: View {
    @Environment(RoonClient.self) private var client
    let selectedID: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(client.zones) { zone in
                    let isOn = zone.id == selectedID
                    Button {
                        withAnimation(Motion.standard) { client.selectZone(zone.id) }
                    } label: {
                        HStack(spacing: Spacing.xs + 2) {
                            Image(systemName: zone.state == .playing ? "speaker.wave.2.fill" : "hifi.speaker")
                                .font(.caption)
                            Text(zone.displayName)
                                .font(.caption.weight(isOn ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.xs + 2)
                        .background(
                            isOn ? AnyShapeStyle(Color.roonGold) : AnyShapeStyle(.quaternary),
                            in: Capsule())
                        // Gold is light — black on gold for AA contrast.
                        .foregroundStyle(isOn ? Color.black : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Wissel naar zone \(zone.displayName)")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(.horizontal, Spacing.lg)
        }
    }
}

// MARK: - Hero (selected zone)

@MainActor
private struct NowPlayingHero: View {
    @Environment(RoonClient.self) private var client
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let zone: Zone

    @State private var volumeValue: Double = 50
    @State private var displayPosition: Double = 0
    @State private var isSeeking = false
    @State private var feat: (bpm: Double, camelot: String, tags: [String])?
    @State private var startingRadio = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer(minLength: Spacing.sm)

            art

            // Track info
            VStack(spacing: Spacing.xs) {
                if let np = zone.nowPlaying {
                    Text(np.title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if let artist = np.artist {
                        Text(artist)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let album = np.album {
                        Text(album)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                } else {
                    Text("Er speelt niets")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(zone.displayName)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Spacing.xl)

            featureRow

            scrubber

            transport

            volumeRow

            Spacer(minLength: Spacing.lg)
        }
        .padding(.horizontal, Spacing.xl)
        .onAppear { displayPosition = zone.seekPosition ?? 0; refreshFeatures() }
        .onChange(of: zone.id) { _, _ in displayPosition = zone.seekPosition ?? 0; refreshFeatures() }
        .onChange(of: zone.seekPosition) { _, pos in displayPosition = pos ?? 0 }
        .onChange(of: zone.nowPlaying?.title) { _, _ in refreshFeatures() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if zone.state == .playing, !isSeeking { displayPosition += 1 }
        }
    }

    // MARK: Art — large, springs on track change, shrinks slightly when paused

    private var art: some View {
        ZStack {
            if let key = zone.nowPlaying?.imageKey,
               let url = client.imageURL(forKey: key, size: 600) {
                CachedArtImage(url: url) { artPlaceholder }
                    .id(key)   // new art transitions in instead of mutating in place
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
            } else {
                artPlaceholder
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 420)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .scaleEffect(zone.state == .playing || reduceMotion ? 1.0 : 0.94)
        .animation(reduceMotion ? nil : Motion.spring, value: zone.state)
        .animation(reduceMotion ? nil : Motion.spring, value: zone.nowPlaying?.imageKey)
        .accessibilityHidden(true)
    }

    private var artPlaceholder: some View {
        RoundedRectangle(cornerRadius: Radius.xl)
            .fill(.quaternary)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 64))
                    .foregroundStyle(.tertiary)
            )
    }

    // MARK: Audio features + Sonic Radio

    @ViewBuilder
    private var featureRow: some View {
        if let np = zone.nowPlaying {
            HStack(spacing: Spacing.sm) {
                if let f = feat {
                    if f.bpm > 0 { Badge("\(Int(f.bpm)) BPM", tint: .roonGold) }
                    if !f.camelot.isEmpty { Badge(f.camelot, tint: .roonGold) }
                    if !f.tags.isEmpty {
                        Text(f.tags.prefix(3).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
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
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(startingRadio)
                .accessibilityLabel("Start Sonic Radio")
                .help("Speel een station met tracks die hier sonisch op lijken")
            }
        }
    }

    // MARK: Scrubber

    @ViewBuilder
    private var scrubber: some View {
        if let np = zone.nowPlaying, let length = np.length, length > 0 {
            VStack(spacing: Spacing.xs) {
                Slider(value: $displayPosition, in: 0...Double(length)) { editing in
                    isSeeking = editing
                    if !editing {
                        Task { await client.seek(zoneID: zone.id, seconds: displayPosition) }
                    }
                }
                .tint(Color.roonGold)
                .accessibilityLabel("Afspeelpositie")
                HStack {
                    Text(formatTime(displayPosition))
                    Spacer()
                    Text("−" + formatTime(Double(length) - displayPosition))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: Spacing.xxl) {
            Button {
                Task { await client.previous(zoneID: zone.id) }
            } label: {
                Image(systemName: "backward.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Vorige track")

            Button {
                Task { await client.playPause(zoneID: zone.id) }
            } label: {
                Image(systemName: zone.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.roonGold)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(zone.state == .playing ? "Pauzeer" : "Speel af")

            Button {
                Task { await client.next(zoneID: zone.id) }
            } label: {
                Image(systemName: "forward.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Volgende track")
        }
    }

    // MARK: Volume

    @ViewBuilder
    private var volumeRow: some View {
        if let output = zone.outputs.first, let vol = output.volume {
            HStack(spacing: Spacing.sm) {
                Button {
                    Task { await client.toggleMute(outputID: output.id, muted: !vol.isMuted) }
                } label: {
                    Image(systemName: vol.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, minHeight: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(vol.isMuted ? "Dempen opheffen" : "Dempen")

                Slider(
                    value: $volumeValue,
                    in: Double(vol.min)...Double(max(vol.max, vol.min + 1)),
                    step: Double(max(vol.step, 1))
                ) { editing in
                    if !editing {
                        Task { await client.setVolume(outputID: output.id, value: Int(volumeValue)) }
                    }
                }
                .frame(maxWidth: 260)
                .accessibilityLabel("Volume")
                .onAppear { volumeValue = Double(vol.value) }
                .onChange(of: vol.value) { _, v in volumeValue = Double(v) }

                Text("\(vol.isMuted ? 0 : vol.value)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
        }
    }

    // MARK: Helpers

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
}
