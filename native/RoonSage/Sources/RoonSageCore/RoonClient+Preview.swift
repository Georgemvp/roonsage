#if DEBUG
import Foundation

extension RoonClient {
    /// DEBUG-only: inject mock playback state so the UI can be rendered in the
    /// simulator / SwiftUI previews without a live Roon/server connection. Never
    /// compiled into release builds.
    @MainActor
    public func previewLoad(zones: [Zone],
                            queueTitles: [(title: String, subtitle: String?)] = [],
                            selected: String? = nil) {
        self.zones = zones
        self.zoneMap = Dictionary(uniqueKeysWithValues: zones.map { ($0.id, $0) })
        // queueItems[0] is the current track; [1...] are "up next".
        self.queueItems = queueTitles.enumerated().map { i, t in
            QueueItem(id: i, title: t.title, subtitle: t.subtitle, length: 0, imageKey: nil)
        }
        self.selectedZoneID = selected ?? zones.first?.id
    }
}
#endif
