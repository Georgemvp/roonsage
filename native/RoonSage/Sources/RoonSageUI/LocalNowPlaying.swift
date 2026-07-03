import SwiftUI
import RoonSageCore
#if canImport(UIKit)
import UIKit
#endif

/// Full-screen Now Playing surface for **on-device** ("dit apparaat" / "deze
/// Mac") playback, shown by `NowPlayingView` whenever the local engine is
/// engaged. It mirrors the Roon hero's visual language — blurred-art backdrop,
/// big springy art, gold transport — but binds every control to
/// `LocalPlaybackController` instead of a Roon zone, so playing here is finally
/// reflected and controlled from the marquee screen (not only the mini-player).
@MainActor
struct LocalNowPlayingScreen: View {
    @Environment(RoonClient.self) private var client

    var body: some View {
        let lp = client.localPlayback
        ZStack {
            LocalNowPlayingBackdrop(imageKey: lp.current?.imageKey)
            LocalNowPlayingHero()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Immersive media screen: always light foreground over the darkened art,
        // regardless of the app's light/dark theme (matches the Roon hero).
        .environment(\.colorScheme, .dark)
        .navigationTitle(lp.current?.title ?? Self.deviceNoun)
    }

    #if os(macOS)
    static let deviceNoun = "deze Mac"
    static let deviceIcon = "laptopcomputer"
    #else
    static let deviceNoun = "dit apparaat"
    static let deviceIcon = "iphone"
    #endif
}

// MARK: - Backdrop

@MainActor
private struct LocalNowPlayingBackdrop: View {
    @Environment(RoonClient.self) private var client
    let imageKey: String?
    @State private var artColor: Color?

    var body: some View {
        ZStack {
            if let imageKey, let url = client.imageURL(forKey: imageKey, size: 300) {
                CachedArtImage(url: url) { Color.clear }
                    .id(imageKey)
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
            LinearGradient(
                colors: [.black.opacity(0.15), .black.opacity(0.35), .black.opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(Motion.ambient, value: artColor)
        .task(id: imageKey) {
            guard let imageKey, let url = client.imageURL(forKey: imageKey, size: 64) else {
                artColor = nil; return
            }
            artColor = await ImageCache.shared.dominantColor(for: url)
        }
    }
}

// MARK: - Hero

@MainActor
private struct LocalNowPlayingHero: View {
    @Environment(RoonClient.self) private var client
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSeeking = false
    @State private var seekFraction: Double = 0
    @State private var showFullArt = false

    /// Match the Roon hero's over-wide-region handling on iOS 26 (read the true
    /// window width, centre in the inflated proposal); a plain cap on macOS.
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
        let lp = client.localPlayback
        VStack(spacing: Spacing.md) {
            Spacer(minLength: 0)
            deviceChip
            art(lp)
            Spacer(minLength: 0)
            trackInfo(lp)
            scrubber(lp)
            transport(lp)
            if let err = lp.lastError { errorLine(err) }
            footer(lp)
        }
        .padding(.horizontal, Spacing.xl)
        .frame(width: maxContentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: Device chip

    private var deviceChip: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: LocalNowPlayingScreen.deviceIcon).font(.caption)
            Text("Speelt op \(LocalNowPlayingScreen.deviceNoun)")
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs + 2)
        .background(.quaternary, in: Capsule())
        .accessibilityLabel("Speelt lokaal op \(LocalNowPlayingScreen.deviceNoun)")
    }

    // MARK: Art

    private func art(_ lp: LocalPlaybackController) -> some View {
        ZStack {
            if let key = lp.current?.imageKey, let url = client.imageURL(forKey: key, size: 600) {
                CachedArtImage(url: url) { artPlaceholder }
                    .id(key)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
            } else {
                artPlaceholder
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 420, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .scaleEffect(lp.isPlaying || reduceMotion ? 1.0 : 0.96)
        .animation(reduceMotion ? nil : Motion.spring, value: lp.isPlaying)
        .animation(reduceMotion ? nil : Motion.spring, value: lp.current?.imageKey)
        .onTapGesture { if lp.current?.imageKey != nil { showFullArt = true } }
        .sheet(isPresented: $showFullArt) {
            FullArtworkView(url: lp.current?.imageKey.flatMap { client.imageURL(forKey: $0, size: 1200) })
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

    // MARK: Track info

    @ViewBuilder
    private func trackInfo(_ lp: LocalPlaybackController) -> some View {
        VStack(spacing: Spacing.xs) {
            if let track = lp.current {
                Text(track.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !track.album.isEmpty {
                    Text(track.album)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else {
                Text("Er speelt niets").font(.title3).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Scrubber

    @ViewBuilder
    private func scrubber(_ lp: LocalPlaybackController) -> some View {
        let dur = lp.durationSec
        let hasLength = dur > 0
        // While dragging, follow the finger; otherwise the engine's live position.
        let frac = isSeeking ? seekFraction : (hasLength ? min(max(lp.positionSec / dur, 0), 1) : 0)
        let shownPos = frac * dur
        VStack(spacing: Spacing.xs) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.28)).frame(height: 6)
                    Capsule().fill(Color.roonGold).frame(width: max(0, w * frac), height: 6)
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
                            seekFraction = min(max(v.location.x / w, 0), 1)
                        }
                        .onEnded { v in
                            guard hasLength, w > 0 else { isSeeking = false; return }
                            let f = min(max(v.location.x / w, 0), 1)
                            lp.seek(toFraction: f)
                            isSeeking = false
                        }
                )
            }
            .frame(height: 22)
            .accessibilityElement()
            .accessibilityLabel("Afspeelpositie")
            .accessibilityValue(formatTime(shownPos))

            HStack {
                Text(formatTime(shownPos))
                Spacer()
                Text(hasLength ? "-" + formatTime(dur - shownPos) : "--:--")
            }
            .font(.footnote.weight(.medium).monospacedDigit())
            .foregroundStyle(.primary)
        }
    }

    // MARK: Transport

    private func transport(_ lp: LocalPlaybackController) -> some View {
        HStack(spacing: Spacing.xxl) {
            Button { Haptics.tap(); lp.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Vorige track")

            Button { Haptics.tap(); lp.togglePlayPause() } label: {
                Image(systemName: lp.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(Color.roonGold)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(lp.isPlaying ? "Pauzeer" : "Speel af")

            Button { Haptics.tap(); lp.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Volgende track")
        }
    }

    // MARK: Error + footer

    private func errorLine(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(Color.roonDanger)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func footer(_ lp: LocalPlaybackController) -> some View {
        VStack(spacing: Spacing.xs) {
            if let summary = client.lastLocalPlaybackSummary, summary.blocked > 0 {
                Text("\(summary.playable) van \(summary.requested) speelbaar hier · \(summary.blocked) Qobuz/stream overgeslagen")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button(role: .destructive) {
                Haptics.tap()
                client.stopLocalPlayback()
            } label: {
                Label("Stop afspelen op \(LocalNowPlayingScreen.deviceNoun)", systemImage: "stop.circle")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .accessibilityLabel("Stop lokaal afspelen")
        }
    }

    // MARK: Helpers

    private func formatTime(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
