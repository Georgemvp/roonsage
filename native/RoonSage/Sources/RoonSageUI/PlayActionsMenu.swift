import RoonSageCore
import SwiftUI

/// The uniform play-action vocabulary (LMS-style): every playable entity —
/// track, album, artist, selection — offers the same four verbs plus
/// listen-on-this-device, in the same order, from one component. Embed inside
/// a `contextMenu` (or `Menu`); the entity's tracks are fetched lazily so a
/// grid of hundreds of cells costs nothing until the user actually opens one.
@MainActor
struct PlayActionsMenu: View {
    @Environment(RoonClient.self) private var client
    /// Lazily resolves the entity's tracks in play order.
    let fetch: () async -> [TrackRecord]
    /// Show the "Speel op dit apparaat" (local playback) entry.
    var includeLocal: Bool = true

    var body: some View {
        let hasZone = client.selectedZone != nil
        Button("Speel nu", systemImage: "play.fill") {
            run { records, zone in await client.curateTracks(records, zoneID: zone) }
        }.disabled(!hasZone)
        Button("Speel hierna", systemImage: "text.line.first.and.arrowtriangle.forward") {
            run { records, zone in await client.queueTracks(records, next: true, zoneID: zone) }
        }.disabled(!hasZone)
        Button("Achteraan in wachtrij", systemImage: "text.append") {
            run { records, zone in await client.queueTracks(records, next: false, zoneID: zone) }
        }.disabled(!hasZone)
        Button("Speel geschud", systemImage: "shuffle") {
            run { records, zone in await client.curateTracks(records.shuffled(), zoneID: zone) }
        }.disabled(!hasZone)
        if includeLocal {
            Divider()
            Button("Speel op dit apparaat", systemImage: "iphone") {
                Haptics.tap()
                Task {
                    let records = await fetch()
                    guard !records.isEmpty else { return }
                    await client.playLocally(records)
                }
            }
        }
    }

    private func run(_ action: @escaping (_ records: [TrackRecord], _ zoneID: String) async -> Void) {
        guard let zone = client.selectedZone else { return }
        Haptics.tap()
        Task {
            let records = await fetch()
            guard !records.isEmpty else { return }
            await action(records, zone.id)
        }
    }
}

extension DatabaseManager.LibraryTrackRow {
    /// The play/queue record for this library row.
    var asTrackRecord: TrackRecord {
        TrackRecord(id: id, title: title, artist: artist, album: album, year: year, isLive: isLive)
    }
}
