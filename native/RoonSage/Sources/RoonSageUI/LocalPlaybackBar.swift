import SwiftUI
import RoonSageCore

/// Floating mini-player for on-device ("Deze iPhone") playback. Appears above
/// the tab bar whenever the local engine is engaged, with transport + stop, a
/// thin progress line, and a note when some tracks were skipped because they're
/// streaming-only (Qobuz) and have no on-disk file to play locally.
@MainActor
public struct LocalPlaybackBar: View {
    @Environment(RoonClient.self) private var client
    public init() {}

    public var body: some View {
        let lp = client.localPlayback
        if lp.isEngaged, let track = lp.current {
            VStack(spacing: 0) {
                progressLine(lp)
                HStack(spacing: Spacing.sm) {
                    AlbumArtView(imageKey: track.imageKey, size: 40, cornerRadius: Radius.sm)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Image(systemName: "iphone").font(.caption2)
                            Text(track.artist.isEmpty ? "Deze iPhone" : track.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { lp.previous() } label: { Image(systemName: "backward.fill") }
                        .buttonStyle(.plain)
                        .frame(minWidth: 36, minHeight: 40)
                        .accessibilityLabel("Vorige track")
                    Button { lp.togglePlayPause() } label: {
                        Image(systemName: lp.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 40, minHeight: 40)
                    .foregroundStyle(Color.roonGold)
                    .accessibilityLabel(lp.isPlaying ? "Pauzeer" : "Speel af")
                    Button { lp.next() } label: { Image(systemName: "forward.fill") }
                        .buttonStyle(.plain)
                        .frame(minWidth: 36, minHeight: 40)
                        .accessibilityLabel("Volgende track")
                    Button { client.stopLocalPlayback() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .frame(minWidth: 36, minHeight: 40)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Stop lokaal afspelen")
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)

                if let summary = client.lastLocalPlaybackSummary, summary.blocked > 0 {
                    Text("\(summary.playable) van \(summary.requested) speelbaar op deze iPhone · \(summary.blocked) Qobuz/stream overgeslagen")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.md)
                        .padding(.bottom, Spacing.xs)
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(.white.opacity(0.08))
            )
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            .padding(.horizontal, Spacing.sm)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Lokaal afspelen op deze iPhone: \(track.title)")
        }
    }

    @ViewBuilder
    private func progressLine(_ lp: LocalPlaybackController) -> some View {
        let dur = lp.durationSec
        GeometryReader { geo in
            let frac = dur > 0 ? min(max(lp.positionSec / dur, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(Color.roonGold).frame(width: geo.size.width * frac)
            }
        }
        .frame(height: 2)
    }
}
