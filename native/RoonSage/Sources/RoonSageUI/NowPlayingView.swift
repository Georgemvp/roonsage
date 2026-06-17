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
        ScrollViewReader { proxy in
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
                        .id(zone.id)
                        .accessibilityLabel("Wissel naar zone \(zone.displayName)")
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Spacing.lg)
            }
            // Soft-fade the leading/trailing edges so chips that scroll off the
            // screen taper out instead of looking abruptly chopped in half.
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.04),
                        .init(color: .black, location: 0.96),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing)
            }
            // Keep the active zone fully on screen rather than half-clipped at an edge.
            .onAppear { scrollToSelected(proxy) }
            .onChange(of: selectedID) { _, _ in scrollToSelected(proxy) }
        }
    }

    private func scrollToSelected(_ proxy: ScrollViewProxy) {
        // Anchor the active zone to the leading edge so it's always fully shown
        // and no chip is left half-clipped *before* it.
        withAnimation(Motion.standard) { proxy.scrollTo(selectedID, anchor: .leading) }
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
    // Position is interpolated from a wall-clock anchor instead of a blind
    // "+1 every tick": each server poll re-anchors to the true position, and the
    // displayed time is `anchorPosition + elapsed-since-anchor`. This keeps the
    // clock accurate even when timer ticks aren't exactly 1.000 s apart or the
    // poll lands mid-second (the old approach drifted a few seconds per track).
    @State private var anchorPosition: Double = 0
    @State private var anchorDate: Date = .init()
    @State private var isSeeking = false
    @State private var feat: (bpm: Double, camelot: String, tags: [String])?
    @State private var startingRadio = false

    var body: some View {
        // Deterministic layout: the artwork is sized from the available height so
        // the whole control stack below always fits without overflow, and a
        // bounded custom scrubber replaces the full-bleed system Slider.
        GeometryReader { geo in
            let artSide = max(140, min(geo.size.width - Spacing.xl * 2, geo.size.height * 0.37))
            VStack(spacing: Spacing.md) {
                Spacer(minLength: 0)
                art(side: artSide)
                trackInfo
                featureRow
                scrubber
                transport
                volumeRow
                footerRow
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Spacing.xl)
        }
        .onAppear { setAnchor(zone.seekPosition ?? 0); refreshFeatures() }
        .onChange(of: zone.id) { _, _ in setAnchor(zone.seekPosition ?? 0); refreshFeatures() }
        .onChange(of: zone.seekPosition) { _, pos in if !isSeeking { setAnchor(pos ?? 0) } }
        // Pause/resume: re-anchor at the frozen value so resuming continues from
        // where the bar stopped instead of jumping by the paused interval.
        .onChange(of: zone.state) { _, _ in setAnchor(displayPosition) }
        .onChange(of: zone.nowPlaying?.title) { _, _ in refreshFeatures() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in tickPosition() }
        .task { await client.ensureFeedbackLoaded() }
    }

    // MARK: Track info

    @ViewBuilder
    private var trackInfo: some View {
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
                        .font(.subheadline)
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
        .frame(maxWidth: .infinity)
    }

    // MARK: Art — sized to fit; springs on track change, shrinks slightly when paused

    private func art(side: CGFloat) -> some View {
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
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .scaleEffect(zone.state == .playing || reduceMotion ? 1.0 : 0.96)
        .animation(reduceMotion ? nil : Motion.spring, value: zone.state)
        .animation(reduceMotion ? nil : Motion.spring, value: zone.nowPlaying?.imageKey)
        .accessibilityHidden(true)
    }

    private var artPlaceholder: some View {
        RoundedRectangle(cornerRadius: Radius.xl)
            .fill(.quaternary)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 56))
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
                        Text(f.tags.prefix(2).joined(separator: " · "))
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
            .lineLimit(1)
        }
    }

    // MARK: Scrubber — custom, bounded progress bar (the system Slider rendered
    // full-bleed here). Clear track, gold fill, draggable thumb, elapsed/remaining.

    @ViewBuilder
    private var scrubber: some View {
        let length = Double(zone.nowPlaying?.length ?? 0)
        let hasLength = length > 0
        VStack(spacing: Spacing.xs) {
            GeometryReader { geo in
                let w = geo.size.width
                let frac = hasLength ? min(max(displayPosition / length, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.18))
                        .frame(height: 5)
                    Capsule().fill(Color.roonGold)
                        .frame(width: max(0, w * frac), height: 5)
                    if hasLength {
                        Circle().fill(.white)
                            .frame(width: 15, height: 15)
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                            .offset(x: min(max(w * frac - 7.5, 0), w - 15))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard hasLength, w > 0 else { return }
                            isSeeking = true
                            displayPosition = min(max(v.location.x / w, 0), 1) * length
                        }
                        .onEnded { v in
                            guard hasLength, w > 0 else { return }
                            let pos = min(max(v.location.x / w, 0), 1) * length
                            displayPosition = pos
                            setAnchor(pos)   // hold until the next poll confirms
                            Task { await client.seek(zoneID: zone.id, seconds: pos) }
                            isSeeking = false
                        }
                )
            }
            .frame(height: 22)
            .accessibilityElement()
            .accessibilityLabel("Afspeelpositie")
            .accessibilityValue(formatTime(displayPosition))

            HStack {
                Text(formatTime(displayPosition))
                Spacer()
                Text(hasLength ? "-" + formatTime(length - displayPosition) : "--:--")
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: Spacing.xxl) {
            Button {
                Task { await client.previous(zoneID: zone.id) }
            } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Vorige track")

            Button {
                Task { await client.playPause(zoneID: zone.id) }
            } label: {
                Image(systemName: zone.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(Color.roonGold)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(zone.state == .playing ? "Pauzeer" : "Speel af")

            Button {
                Task { await client.next(zoneID: zone.id) }
            } label: {
                Image(systemName: "forward.fill").font(.title)
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
                .tint(Color.roonGold)
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

    // MARK: Footer — like/dislike (teaches radios & recommendations) + up-next

    @ViewBuilder
    private var footerRow: some View {
        if let np = zone.nowPlaying {
            let current = client.feedbackFor(title: np.title, artist: np.artist, album: np.album)
            HStack(spacing: Spacing.lg) {
                Button {
                    Haptics.tap()
                    Task { await client.setFeedback(.like, title: np.title, artist: np.artist, album: np.album) }
                } label: {
                    Image(systemName: current == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.title3)
                        .foregroundStyle(current == .like ? Color.roonGold : .secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Vind ik leuk")
                .accessibilityAddTraits(current == .like ? .isSelected : [])

                Button {
                    Haptics.tap()
                    Task { await client.setFeedback(.dislike, title: np.title, artist: np.artist, album: np.album) }
                } label: {
                    Image(systemName: current == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.title3)
                        .foregroundStyle(current == .dislike ? Color.roonDanger : .secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Vind ik niet leuk — sla over en leer ervan")
                .accessibilityAddTraits(current == .dislike ? .isSelected : [])

                if let next = nextUpItem {
                    Spacer(minLength: Spacing.sm)
                    nextUpPill(next)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func nextUpPill(_ next: RoonClient.QueueItem) -> some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .trailing, spacing: 1) {
                Text("Hierna").font(.caption2).foregroundStyle(.tertiary)
                Text(next.title).font(.caption.weight(.medium)).lineLimit(1)
                if let s = next.subtitle, !s.isEmpty {
                    Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            AlbumArtView(imageKey: next.imageKey, size: 36)
            Image(systemName: "forward.end.fill")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            Task { await client.next(zoneID: zone.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hierna: \(next.title)\(next.subtitle.map { " — \($0)" } ?? "")")
        .accessibilityHint("Tik om door te spelen")
    }

    private var nextUpItem: RoonClient.QueueItem? {
        client.queueItems.count > 1 ? client.queueItems[1] : nil
    }

    // MARK: Helpers

    private func formatTime(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Pin the displayed position to a known-true value (server poll, seek, track
    /// change) and stamp the wall clock so `tickPosition` can interpolate from it.
    private func setAnchor(_ pos: Double) {
        anchorPosition = max(0, pos)
        anchorDate = Date()
        displayPosition = anchorPosition
    }

    /// Advance the displayed position from real elapsed wall-clock time while
    /// playing — accurate regardless of timer jitter; clamped to the track length.
    private func tickPosition() {
        guard zone.state == .playing, !isSeeking else { return }
        var p = anchorPosition + Date().timeIntervalSince(anchorDate)
        if let len = zone.nowPlaying?.length, len > 0 { p = min(p, Double(len)) }
        displayPosition = p
    }

    private func refreshFeatures() {
        if let np = zone.nowPlaying {
            feat = client.featuresFor(title: np.title, artist: np.artist, album: np.album)
        } else {
            feat = nil
        }
    }
}
