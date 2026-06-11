import WidgetKit
import SwiftUI
import ActivityKit

/// Roon gold (#e5a00d) — duplicated from RoonSageUI.Theme because the widget
/// extension stays dependency-free (no SPM package link).
private let roonGold = Color(red: 0.898, green: 0.627, blue: 0.051)

@main
struct RoonSageWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingLiveActivity()
    }
}

/// Lock-screen banner + Dynamic Island for the zone that's playing.
/// Album art is intentionally absent in v1: the Roon Core's image server is
/// only reachable through the app's open connection, not from the extension.
struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            // Lock screen / banner presentation.
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.8))
                .activitySystemActionForegroundColor(roonGold)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "music.note")
                        .font(.title2)
                        .foregroundStyle(roonGold)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.title)
                            .font(.headline)
                            .lineLimit(1)
                        if let artist = context.state.artist {
                            Text(artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(context.attributes.zoneName, systemImage: "hifispeaker")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        elapsedView(context.state)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "music.note")
                    .foregroundStyle(roonGold)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
                    .foregroundStyle(roonGold)
            } minimal: {
                Image(systemName: "music.note")
                    .foregroundStyle(roonGold)
            }
        }
    }

    @ViewBuilder
    private func elapsedView(_ state: NowPlayingAttributes.ContentState) -> some View {
        if state.isPlaying, let start = state.startedAt {
            // System-driven timer: ticks without activity updates from the app.
            Text(timerInterval: start...start.addingTimeInterval(
                state.length > 0 ? TimeInterval(state.length) : 6 * 3600
            ), countsDown: false)
        } else {
            Text(state.isPlaying ? "" : "Gepauzeerd")
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<NowPlayingAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.title)
                .foregroundStyle(roonGold)
                .frame(width: 44, height: 44)
                .background(roonGold.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let artist = context.state.artist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Image(systemName: "hifispeaker")
                        .font(.caption2)
                    Text(context.attributes.zoneName)
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
                .font(.title3)
                .foregroundStyle(roonGold)
        }
        .padding(14)
    }
}
