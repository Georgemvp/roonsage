import SwiftUI
import RoonSageCore
#if canImport(UIKit)
import UIKit
#endif

/// Immersive Now Playing: the selected zone is the showpiece — full-bleed
/// blurred-art backdrop, large springy album art, generous scrubber and gold
/// transport — with a compact switcher strip for the other zones. The old
/// version was a uniform list of small zone cards; a music app's marquee
/// screen deserves more than a 56-pt thumbnail.
public struct NowPlayingView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    public var body: some View {
        if client.localOutputSelected {
            // Listening on this device: the local engine owns the marquee screen,
            // so on-device playback is shown and controlled here — not only in the
            // floating mini-player. Shown whenever "dit apparaat" is the CHOSEN
            // output (even idle). Deliberately keyed on the selected output, not
            // on `localPlayback.isEngaged`: picking a Roon zone must switch this
            // screen to that zone even while local audio keeps playing in the
            // background (reachable again via the output picker → "dit apparaat").
            // Otherwise a lingering local session made the zone picker look dead.
            LocalNowPlayingScreen()
        } else if client.zones.isEmpty {
            ContentUnavailableView(
                "Geen actieve zones",
                systemImage: "speaker.slash",
                description: Text("Start afspelen in Roon om hier zones te zien.")
            )
        } else if let zone = client.selectedZone {
            ZStack {
                NowPlayingBackdrop(zone: zone)
                VStack(spacing: 0) {
                    // iOS hides the nav bar here, so the body carries the output
                    // switcher. A Menu (not a scrolling strip) never clips and is
                    // immune to window/scene resizing. On macOS the toolbar
                    // already provides the picker, so no in-body duplicate. Always
                    // shown so you can switch to "dit apparaat" even with one zone.
                    #if os(iOS)
                    OutputSelector()
                        .padding(.top, Spacing.sm)
                        .padding(.bottom, Spacing.xs)
                    #endif
                    NowPlayingHero(zone: zone)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Immersive media screen: always light foreground over the darkened
            // art backdrop, regardless of the app's light/dark theme — otherwise
            // a light theme would render black controls invisible on the scrim.
            .environment(\.colorScheme, .dark)
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

// MARK: - Shared playback-option helpers

/// Roon loop-mode cycling + labels, shared by the Now Playing hero and the
/// Queue toolbar so the two surfaces never drift.
enum NowPlayingHeroOptions {
    /// Cycle Roon's loop setting: off → all → one → off.
    static func nextLoop(_ current: String) -> String {
        switch current {
        case "disabled": "loop"
        case "loop":     "loop_one"
        default:         "disabled"
        }
    }

    static func loopLabel(_ loop: String) -> String {
        switch loop {
        case "loop":     "Herhaal alles"
        case "loop_one": "Herhaal deze track"
        default:         "Herhalen uit"
        }
    }

    /// Compact Dutch labels for the strong attribute axes (max 2) — the eyeball
    /// UI shared by the zone hero and the local (on-device) hero.
    static func attributeBadges(_ attrs: [String: Float]) -> [String] {
        guard !attrs.isEmpty else { return [] }
        let rules: [(key: String, high: String, low: String)] = [
            ("valence", "Vrolijk", "Melancholisch"),
            ("danceability", "Dansbaar", ""),
            ("acousticness", "Akoestisch", "Elektronisch"),
            ("instrumentalness", "Instrumentaal", ""),
        ]
        var out: [String] = []
        for r in rules {
            guard let v = attrs[r.key] else { continue }
            if v >= 0.62, !r.high.isEmpty { out.append(r.high) }
            else if v <= 0.38, !r.low.isEmpty { out.append(r.low) }
            if out.count >= 2 { break }
        }
        return out
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
            blurredArt
            Rectangle().fill(.regularMaterial)
            if let artColor {
                LinearGradient(
                    colors: [artColor.opacity(0.35), artColor.opacity(0.05), .clear],
                    startPoint: .top, endPoint: .bottom
                )
            }
            // Dark scrim so the white foreground (track title, scrubber, volume,
            // like/dislike) always has contrast — a bright album cover would
            // otherwise wash it all out. Heaviest toward the bottom, where the
            // controls sit; the artwork up top stays vibrant.
            LinearGradient(
                colors: [.black.opacity(0.15), .black.opacity(0.35), .black.opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(Motion.ambient, value: artColor)
        .task(id: zone.nowPlaying?.imageKey) {
            guard let key = zone.nowPlaying?.imageKey,
                  let url = client.imageURL(forKey: key, size: 64) else { artColor = nil; return }
            artColor = await ImageCache.shared.dominantColor(for: url)
        }
    }

    @ViewBuilder
    private var blurredArt: some View {
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
    }
}

// MARK: - Output switcher

/// Single dropdown pill for switching the playback output — every Roon zone plus
/// "dit apparaat" (on-device playback), so the local player is a first-class
/// output alongside the zones. A `Menu` (not a horizontal strip) can't clip a
/// chip and is unaffected by window/scene resizing. Shared by the zone hero and
/// the local Now Playing screen so the two never drift.
@MainActor
struct OutputSelector: View {
    @Environment(RoonClient.self) private var client
    @AppStorage("lastZoneID") private var lastZoneID: String = ""

    var body: some View {
        let localOn = client.localOutputSelected
        let active = client.selectedZone
        Menu {
            ForEach(client.zones) { zone in
                Button {
                    client.selectZone(zone.id); lastZoneID = zone.id; Haptics.tap()
                } label: {
                    Label(zone.displayName,
                          systemImage: (!localOn && zone.id == active?.id) ? "checkmark"
                              : (zone.state == .playing ? "speaker.wave.2.fill" : "hifi.speaker"))
                }
            }
            Divider()
            Button {
                client.selectLocalOutput(); Haptics.tap()
            } label: {
                Label(RoonClient.localOutputName,
                      systemImage: localOn ? "checkmark" : RoonClient.localOutputIcon)
            }
        } label: {
            HStack(spacing: Spacing.xs + 2) {
                Image(systemName: localOn ? RoonClient.localOutputIcon
                          : (active?.state == .playing ? "speaker.wave.2.fill" : "hifi.speaker"))
                    .font(.caption)
                Text(localOn ? RoonClient.localOutputName : (active?.displayName ?? "Kies output"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.7)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs + 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Output: \(localOn ? RoonClient.localOutputName : (active?.displayName ?? "geen"))")
        .accessibilityHint("Tik om een andere zone of dit apparaat te kiezen")
    }
}

// MARK: - Hero (selected zone)

@MainActor
private struct NowPlayingHero: View {
    @Environment(RoonClient.self) private var client
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.navigateTo) private var navigateTo
    let zone: Zone

    init(zone: Zone) {
        self.zone = zone
        // Seed from the zone so the very first frame shows the real position and
        // volume (no flash from 0 / 50, and it renders correctly off-screen too).
        let seek = zone.seekPosition ?? 0
        _displayPosition = State(initialValue: seek)
        _anchorPosition = State(initialValue: seek)
        _volumeValue = State(initialValue: Double(zone.outputs.first?.volume?.value ?? 50))
    }

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
    @State private var attrs: [String: Float] = [:]
    @State private var startingRadio = false
    @State private var startingAdventure = false
    @State private var showLyrics = false
    @State private var showFullArt = false
    @State private var similarSeed: SonicSeed?
    @AppStorage("showVisualizer") private var showVisualizer = true

    /// The real width to bound the hero to. On iOS we read the active window's
    /// width directly (capped for iPad) instead of trusting the layout proposal,
    /// which iOS 26.6 inflates beyond the screen for hidden-bar NavigationStack
    /// content. On macOS the window is correctly sized, so a plain cap suffices.
    private var maxContentWidth: CGFloat {
        #if canImport(UIKit)
        let windowWidth = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.width }
            .first ?? UIScreen.main.bounds.width
        return min(windowWidth > 0 ? windowWidth : 560, 560)
        #else
        return 560
        #endif
    }

    var body: some View {
        // iOS 26.6 proposes an OVER-WIDE layout region to this NavigationStack
        // content with a hidden bar — ~560pt on a 390pt iPhone 13 (fine on 26.5).
        // So neither a greedy GeometryReader (it READS 560) nor `.frame(maxWidth:
        // .infinity)` (it CLAMPS to 560) can keep the content on screen: the
        // title overflowed both edges and the controls were pushed off. Fix:
        // bound the stack to the TRUE screen/window width (read from UIKit, not
        // from the bad proposal) and centre it in the over-wide region — since
        // the region is centred on the screen, content at the real width lands
        // correctly. No GeometryReader, so nothing can read the inflated width.
        VStack(spacing: Spacing.md) {
            Spacer(minLength: 0)
            art
            Spacer(minLength: 0)
            trackInfo
            featureRow
            visualizer
            scrubber
            transport
            optionsRow
            volumeRow
            footerRow
        }
        .padding(.horizontal, Spacing.xl)
        .frame(width: maxContentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, Spacing.sm)
        .onAppear { setAnchor(zone.seekPosition ?? 0) }
        .onChange(of: zone.id) { _, _ in setAnchor(zone.seekPosition ?? 0) }
        .task(id: zone.id) { await refreshFeatures() }
        .task(id: zone.nowPlaying?.title) { await refreshFeatures() }
        .onChange(of: zone.seekPosition) { _, pos in if !isSeeking { setAnchor(pos ?? 0) } }
        // Pause/resume: re-anchor at the frozen value so resuming continues from
        // where the bar stopped instead of jumping by the paused interval.
        .onChange(of: zone.state) { _, _ in setAnchor(displayPosition) }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in tickPosition() }
        .task { await client.ensureFeedbackLoaded() }
        .sheet(isPresented: $showLyrics) { LyricsView(zone: zone) }
        .similarTracksSheet(item: $similarSeed)
    }

    // MARK: Track info

    @ViewBuilder
    private var trackInfo: some View {
        VStack(spacing: Spacing.xs) {
            if let np = zone.nowPlaying {
                Text(np.title.displayTitle)
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
                // A discovery app shouldn't dead-end here — offer a way to start.
                HStack(spacing: Spacing.sm) {
                    Button {
                        Haptics.tap(); navigateTo(.discovery)
                    } label: {
                        Label("Ontdek muziek", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        Haptics.tap(); navigateTo(.generate)
                    } label: {
                        Label("Maak een playlist", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.callout)
                .padding(.top, Spacing.md)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Art — sized to fit; springs on track change, shrinks slightly when paused

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
        // Square, capped for large screens, and free to SHRINK to the space left
        // after the controls — no fixed size, so no GeometryReader is needed.
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 420, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .scaleEffect(zone.state == .playing || reduceMotion ? 1.0 : 0.96)
        .animation(reduceMotion ? nil : Motion.spring, value: zone.state)
        .animation(reduceMotion ? nil : Motion.spring, value: zone.nowPlaying?.imageKey)
        // Tap → full-screen artwork (LMS's cover modal).
        .onTapGesture {
            if zone.nowPlaying?.imageKey != nil { showFullArt = true }
        }
        .sheet(isPresented: $showFullArt) {
            FullArtworkView(url: zone.nowPlaying?.imageKey.flatMap { client.imageURL(forKey: $0, size: 1200) })
        }
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
                // CLAP attribute axes (when analyzed) — the "meer meta" the engine
                // can use; shown here so you can eyeball the values per track.
                ForEach(NowPlayingHeroOptions.attributeBadges(attrs), id: \.self) { label in
                    Badge(label, tint: .secondary)
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

                Button {
                    startingAdventure = true
                    Task {
                        await client.playSonicAdventure(title: np.title, artist: np.artist, album: np.album, zoneID: zone.id)
                        startingAdventure = false
                    }
                } label: {
                    if startingAdventure {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Reis", systemImage: "map").font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(startingAdventure)
                .accessibilityLabel("Start een sonische reis")
                .help("Een sonische reis die vanaf deze track wegdrijft naar een heel ander klankgebied")
            }
            .lineLimit(1)
        }
    }

    // MARK: Visualizer — beat-driven equalizer fed by the analyzer's BPM/energy/
    // valence (no audio tap needed; works for any Roon zone). Only while a track
    // with a known tempo is loaded, and opt-out via Settings → Verschijning.

    @ViewBuilder
    private var visualizer: some View {
        if showVisualizer, zone.nowPlaying != nil, let f = feat, f.bpm > 0 {
            BeatVisualizer(
                bpm: f.bpm,
                intensity: Double(attrs["danceability"] ?? attrs["energy"] ?? 0.55),
                warmth: Double(attrs["valence"] ?? 0.5),
                isPlaying: zone.state == .playing,
                reduceMotion: reduceMotion
            )
            .padding(.horizontal, Spacing.sm)
            .transition(.opacity)
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
                    Capsule().fill(Color.white.opacity(0.28))
                        .frame(height: 6)
                    Capsule().fill(Color.roonGold)
                        .frame(width: max(0, w * frac), height: 6)
                    // Always show the knob (even at 0:00) so the bar clearly reads
                    // as a scrubber rather than a flat line.
                    Circle().fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: min(max(w * frac - 8, 0), w - 16))
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
            .accessibilityHint("Veeg omhoog of omlaag om te spoelen")
            .accessibilityAdjustableAction { direction in
                guard hasLength else { return }
                let step = length * 0.05
                let target = direction == .increment
                    ? min(displayPosition + step, length)
                    : max(displayPosition - step, 0)
                displayPosition = target
                setAnchor(target)   // hold until the next poll confirms
                Task { await client.seek(zoneID: zone.id, seconds: target) }
            }

            HStack {
                Text(formatTime(displayPosition))
                Spacer()
                Text(hasLength ? "-" + formatTime(length - displayPosition) : "--:--")
            }
            .font(.footnote.weight(.medium).monospacedDigit())
            .foregroundStyle(.primary)
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

    // MARK: Shuffle / repeat
    //
    // Roon exposes these via zone.settings; the state reflects the live snapshot
    // so the icons stay in sync when changed from Roon itself or another remote.
    // (setShuffle/setRepeat already existed in Core but were never wired to any
    // SwiftUI view — only the remote/MCP command path.)

    private var optionsRow: some View {
        let shuffleOn = zone.shuffle ?? false
        let loop = zone.loopMode ?? "disabled"
        return HStack(spacing: Spacing.xxl) {
            Button {
                Haptics.tap()
                Task { await client.setShuffle(zoneID: zone.id, enabled: !shuffleOn) }
            } label: {
                Image(systemName: "shuffle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(shuffleOn ? Color.roonGold : .secondary)
                    .tappable44()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shuffle")
            .accessibilityValue(shuffleOn ? "aan" : "uit")
            .accessibilityAddTraits(shuffleOn ? .isSelected : [])

            Button {
                Haptics.tap()
                Task { await client.setRepeat(zoneID: zone.id, mode: NowPlayingHeroOptions.nextLoop(loop)) }
            } label: {
                Image(systemName: loop == "loop_one" ? "repeat.1" : "repeat")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(loop == "disabled" ? .secondary : Color.roonGold)
                    .tappable44()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NowPlayingHeroOptions.loopLabel(loop))
            .accessibilityAddTraits(loop == "disabled" ? [] : .isSelected)
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
                        .tappable44()
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
                // Neutral tint (not gold) so the volume reads as a separate
                // control and isn't mistaken for a second progress bar.
                .tint(.white.opacity(0.55))
                .controlSize(.small)
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
                        .foregroundStyle(current == .like ? Color.roonGold : .primary)
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
                        .foregroundStyle(current == .dislike ? Color.roonDanger : .primary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Vind ik niet leuk — sla over en leer ervan")
                .accessibilityAddTraits(current == .dislike ? .isSelected : [])

                Button {
                    Haptics.tap()
                    showLyrics = true
                } label: {
                    Image(systemName: "quote.bubble")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Songtekst")

                Button {
                    Haptics.tap()
                    similarSeed = SonicSeed(title: np.title, artist: np.artist,
                                            album: np.album, imageKey: np.imageKey)
                } label: {
                    Image(systemName: "waveform.path.ecg")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sonisch vergelijkbaar")

                if let next = nextUpItem {
                    Spacer(minLength: Spacing.sm)
                    // Lower layout priority so a long "up next" title never
                    // squeezes the like/dislike buttons off the leading edge.
                    nextUpPill(next).layoutPriority(-1)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func nextUpPill(_ next: RoonClient.QueueItem) -> some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .trailing, spacing: 1) {
                Text("Hierna").font(.caption2).foregroundStyle(.secondary)
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

    private func refreshFeatures() async {
        if let np = zone.nowPlaying {
            feat = await client.featuresFor(title: np.title, artist: np.artist, album: np.album)
            attrs = await client.attributesFor(title: np.title, artist: np.artist, album: np.album)
        } else {
            feat = nil
            attrs = [:]
        }
    }
}

// MARK: - Full-screen artwork (tap the hero art)

@MainActor
struct FullArtworkView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url {
                CachedArtImage(url: url) {
                    ProgressView().controlSize(.large)
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 72)).foregroundStyle(.secondary)
            }
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding()
                    .accessibilityLabel("Sluit")
                }
                Spacer()
            }
        }
        .onTapGesture { dismiss() }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 600)
        #endif
    }
}
