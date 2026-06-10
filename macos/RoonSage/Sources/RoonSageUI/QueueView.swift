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
                ContentUnavailableView("No zone selected", systemImage: "list.number",
                    description: Text("Pick a zone in the toolbar to see its queue."))
            } else if client.queueItems.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "list.number",
                    description: Text("Nothing queued in \(client.selectedZone?.displayName ?? "this zone")."))
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
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Queue")
        .onAppear(perform: restart)
        .onChange(of: client.selectedZone?.id) { _, _ in restart() }
        .onDisappear { client.stopQueue() }
    }

    private func restart() {
        if let zone = client.selectedZone?.id { client.startQueue(zoneID: zone) }
    }

    private func playFromHere(_ item: RoonClient.QueueItem) {
        guard let zone = client.selectedZone?.id else { return }
        Task { await client.playFromHere(zoneID: zone, queueItemID: item.id) }
    }

    private func formatTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
