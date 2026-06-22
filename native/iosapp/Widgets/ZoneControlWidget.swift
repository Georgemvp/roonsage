import WidgetKit
import SwiftUI
import AppIntents

private let widgetGold = Color(red: 0.898, green: 0.627, blue: 0.051)

/// Home-screen / Lock Screen "Zone Control": toont wat er speelt in de
/// geselecteerde Roon-zone met interactieve play/pause en volgende-track.
/// Data komt uit de App Group-snapshot die de app bij elke wissel schrijft
/// (en dan `reloadAllTimelines` aanroept) — geen eigen polling.
struct ZoneControlWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ZoneControl", provider: ZoneControlProvider()) { entry in
            ZoneControlView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Roon-zone")
        .description("Zie wat er speelt en bedien je Roon-zone.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct ZoneControlEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedNowPlaying?
}

struct ZoneControlProvider: TimelineProvider {
    func placeholder(in context: Context) -> ZoneControlEntry {
        ZoneControlEntry(date: .now, snapshot: SharedNowPlaying(
            title: "Champagne Supernova", artist: "Oasis",
            zoneName: "Woonkamer", isPlaying: true, updatedAt: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (ZoneControlEntry) -> Void) {
        completion(ZoneControlEntry(date: .now, snapshot: currentSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ZoneControlEntry>) -> Void) {
        // De app pusht verse data via reloadAllTimelines; zelf hoeven we
        // alleen de versheid te bewaken (na een uur terug naar leeg).
        let entry = ZoneControlEntry(date: .now, snapshot: currentSnapshot())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }

    private func currentSnapshot() -> SharedNowPlaying? {
        guard let snap = SharedNowPlaying.load(), snap.isFresh else { return nil }
        return snap
    }
}

struct ZoneControlView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ZoneControlEntry

    var body: some View {
        if let snap = entry.snapshot {
            switch family {
            case .accessoryRectangular: accessory(snap)
            case .systemMedium:         medium(snap)
            default:                    small(snap)
            }
        } else {
            empty
        }
    }

    private var empty: some View {
        VStack(spacing: 4) {
            Image(systemName: "music.note.house")
                .font(.title2)
                .foregroundStyle(widgetGold)
            Text("Open RoonSage om te verbinden")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func small(_ snap: SharedNowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "hifispeaker.fill")
                    .font(.caption2)
                    .foregroundStyle(widgetGold)
                Text(snap.zoneName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            Spacer(minLength: 0)
            Text(snap.title)
                .font(.subheadline.bold())
                .lineLimit(2)
            if let artist = snap.artist {
                Text(artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Button(intent: PlayPauseIntent()) {
                    Image(systemName: snap.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(widgetGold)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(snap.isPlaying ? "Pauzeer" : "Speel af")
                Button(intent: NextTrackIntent()) {
                    Image(systemName: "forward.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Volgende track")
                Spacer()
            }
        }
    }

    private func medium(_ snap: SharedNowPlaying) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "hifispeaker.fill").font(.caption2)
                    Text(snap.zoneName).font(.caption)
                }
                .foregroundStyle(.secondary)
                Text(snap.title)
                    .font(.headline)
                    .lineLimit(2)
                if let artist = snap.artist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button(intent: PreviousTrackIntent()) {
                    Image(systemName: "backward.fill")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Vorige track")
                Button(intent: PlayPauseIntent()) {
                    Image(systemName: snap.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(widgetGold)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(snap.isPlaying ? "Pauzeer" : "Speel af")
                Button(intent: NextTrackIntent()) {
                    Image(systemName: "forward.fill")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Volgende track")
            }
        }
    }

    private func accessory(_ snap: SharedNowPlaying) -> some View {
        HStack(spacing: 8) {
            Image(systemName: snap.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
            VStack(alignment: .leading, spacing: 1) {
                Text(snap.title).font(.headline).lineLimit(1)
                Text(snap.artist ?? snap.zoneName).font(.caption2).lineLimit(1)
            }
        }
    }
}
