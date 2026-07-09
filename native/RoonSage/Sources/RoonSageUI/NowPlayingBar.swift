import SwiftUI
import RoonSageCore

/// Compact, **tappable** "now playing" bar that sits above the tab bar (iPhone)
/// or at the bottom of the window (macOS / iPad). It shows on-device
/// ("dit apparaat") playback when the local engine is engaged, otherwise the
/// selected Roon zone. Tapping anywhere but the transport buttons opens the full
/// Now Playing screen. This replaces the old local-only `LocalPlaybackBar`.
///
/// Positioning: attach with `.safeAreaInset(edge: .bottom)` to the content
/// *inside* each tab's `NavigationStack` (not around the whole `TabView`) so the
/// bar is pushed above the system tab buttons instead of floating over them.
@MainActor
public struct NowPlayingBar: View {
    @Environment(RoonClient.self) private var client
    @Environment(\.navigateTo) private var navigateTo
    public init() {}

    #if os(macOS)
    private static let localIcon = "laptopcomputer"
    private static let localNoun = "Deze Mac"
    #else
    private static let localIcon = "iphone"
    private static let localNoun = "Dit apparaat"
    #endif

    public var body: some View {
        let lp = client.localPlayback
        if lp.isEngaged, let track = lp.current {
            // On-device playback takes precedence over any Roon zone.
            bar(
                imageKey: track.imageKey,
                title: track.title,
                subtitle: track.artist.isEmpty ? Self.localNoun : track.artist,
                subtitleIcon: Self.localIcon,
                isPlaying: lp.isPlaying,
                progress: lp.durationSec > 0 ? lp.positionSec / lp.durationSec : nil,
                onToggle: { Haptics.tap(); lp.togglePlayPause() },
                onNext: { Haptics.tap(); lp.next() },
                onStop: { client.stopLocalPlayback() },
                // Re-select the on-device output so opening Now Playing shows the
                // local screen (not a Roon zone that was picked while local kept
                // playing in the background).
                onOpen: { client.selectLocalOutput(); navigateTo(.nowPlaying) },
                accessibilityLabel: "Lokaal afspelen op \(Self.localNoun): \(track.title). Tik om Nu speelt te openen."
            )
        } else if let zone = client.selectedZone, let np = zone.nowPlaying,
                  zone.state == .playing || zone.state == .paused {
            bar(
                imageKey: np.imageKey,
                title: np.title,
                subtitle: np.artist ?? zone.displayName,
                subtitleIcon: "hifi.speaker",
                isPlaying: zone.state == .playing,
                progress: zoneProgress(zone, np),
                onToggle: { Haptics.tap(); Task { await client.playPause(zoneID: zone.id) } },
                onNext: { Haptics.tap(); Task { await client.next(zoneID: zone.id) } },
                onStop: nil,
                onOpen: { navigateTo(.nowPlaying) },
                accessibilityLabel: "Speelt in \(zone.displayName): \(np.title). Tik om Nu speelt te openen."
            )
        }
    }

    private func zoneProgress(_ zone: Zone, _ np: NowPlaying) -> Double? {
        guard let pos = zone.seekPosition, let len = np.length, len > 0 else { return nil }
        return min(max(pos / Double(len), 0), 1)
    }

    // MARK: - Shared layout

    @ViewBuilder
    private func bar(
        imageKey: String?,
        title: String,
        subtitle: String,
        subtitleIcon: String,
        isPlaying: Bool,
        progress: Double?,
        onToggle: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onStop: (() -> Void)?,
        onOpen: @escaping () -> Void,
        accessibilityLabel: String
    ) -> some View {
        VStack(spacing: 0) {
            progressLine(progress)
            HStack(spacing: Spacing.sm) {
                // Tapping the art + labels expands into the full Now Playing screen.
                Button { onOpen() } label: {
                    HStack(spacing: Spacing.sm) {
                        AlbumArtView(imageKey: imageKey, size: 40, cornerRadius: Radius.sm)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Image(systemName: subtitleIcon).font(.caption2)
                                Text(subtitle)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onToggle) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 40, minHeight: 40)
                .foregroundStyle(Color.roonGold)
                .accessibilityLabel(isPlaying ? "Pauzeer" : "Speel af")

                Button(action: onNext) {
                    Image(systemName: "forward.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 36, minHeight: 40)
                .accessibilityLabel("Volgende track")

                if let onStop {
                    Button(action: onStop) { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .frame(minWidth: 32, minHeight: 40)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Stop lokaal afspelen")
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
        }
        // Docked, full-width bar flush above the tab bar (not a floating card):
        // same `.bar` material as the system tab bar below it, with a top hairline
        // so it reads as part of the chrome instead of hovering over content. The
        // enclosing `.safeAreaInset(edge: .bottom)` reserves its height so list
        // rows rest above it rather than sliding underneath.
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func progressLine(_ progress: Double?) -> some View {
        GeometryReader { geo in
            let frac = min(max(progress ?? 0, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(Color.roonGold).frame(width: geo.size.width * frac)
            }
        }
        .frame(height: 2)
        .opacity(progress == nil ? 0 : 1)
    }
}

// MARK: - Attachment helper

extension View {
    /// Pins the shared `NowPlayingBar` above this view's bottom edge. Pass
    /// `hidden: true` on the Now Playing screen itself (where the full hero
    /// already shows and controls playback) to avoid a duplicate transport.
    @MainActor @ViewBuilder
    public func nowPlayingBarInset(hidden: Bool = false) -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0) {
            if !hidden { NowPlayingBar() }
        }
    }

    /// Docks the shared `NowPlayingBar` as a real layout sibling *below* this view
    /// (typically a tab's `NavigationStack`), so it occupies genuine vertical space
    /// instead of overlaying the content. Use this on iOS tabs: a bottom
    /// `safeAreaInset` on a `NavigationStack` does **not** reliably inset a
    /// large-title `List`'s scroll content, so rows slide under the bar; a VStack
    /// sibling can't be scrolled under. When nothing is playing the bar renders
    /// empty (zero height) and the wrapped view fills the whole area. Because the
    /// bar sits outside the `NavigationStack`, it also persists across pushes.
    @MainActor @ViewBuilder
    public func nowPlayingBarDocked(hidden: Bool = false) -> some View {
        VStack(spacing: 0) {
            self
            if !hidden { NowPlayingBar() }
        }
    }
}
