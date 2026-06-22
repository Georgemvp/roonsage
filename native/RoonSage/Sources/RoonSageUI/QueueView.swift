import RoonSageCore
import SwiftUI

/// The selected zone's Roon play queue. Tap a track to jump to it (play from
/// here). Roon's extension API is read + play-from-here only (no reorder/remove).
@MainActor
public struct QueueView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    public var body: some View {
        Group {
            if client.selectedZone == nil {
                ContentUnavailableView("Geen zone gekozen", systemImage: "list.number",
                    description: Text("Kies een zone in de werkbalk om de wachtrij te zien."))
            } else if client.queueItems.isEmpty {
                ContentUnavailableView("Wachtrij is leeg", systemImage: "list.number",
                    description: Text("Niets in de wachtrij van \(client.selectedZone?.displayName ?? "deze zone")."))
            } else {
                List {
                    ForEach(Array(client.queueItems.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            AlbumArtView(imageKey: item.imageKey, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .lineLimit(1)
                                    .fontWeight(index == 0 ? .semibold : .regular)
                                if let s = item.subtitle {
                                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if index == 0 {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.caption).foregroundStyle(Color.roonGold)
                            } else if item.length > 0 {
                                Text(formatTime(item.length))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { playFromHere(item) }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(queueLabel(item, isNowPlaying: index == 0))
                        .accessibilityHint("Tik om vanaf hier af te spelen")
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Wachtrij")
        .onAppear(perform: restart)
        .onChange(of: client.selectedZone?.id) { _, _ in restart() }
        .onDisappear { client.stopQueue() }
    }

    private func restart() {
        if let zone = client.selectedZone?.id { client.startQueue(zoneID: zone) }
    }

    private func playFromHere(_ item: RoonClient.QueueItem) {
        guard let zone = client.selectedZone?.id else { return }
        Haptics.tap()
        Task { await client.playFromHere(zoneID: zone, queueItemID: item.id) }
    }

    private func queueLabel(_ item: RoonClient.QueueItem, isNowPlaying: Bool) -> String {
        var parts: [String] = []
        if isNowPlaying { parts.append("Speelt nu") }
        parts.append(item.title)
        if let s = item.subtitle { parts.append(s) }
        return parts.joined(separator: ", ")
    }

    private func formatTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
