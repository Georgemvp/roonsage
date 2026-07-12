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
    /// When set (single-track contexts), offer "Radio op dit nummer" — an
    /// endless sonic station seeded on exactly this track (song radio).
    var trackRadioSeed: TrackRecord? = nil

    var body: some View {
        let hasZone = client.selectedZone != nil
        // The primary "play now" verbs follow the active output — the selected
        // Roon zone, or this device when "dit apparaat" is chosen. The queue verbs
        // are Roon-only (the local engine has no insert-next), so they stay zoned.
        let hasOutput = client.hasActiveOutput
        Button("Speel nu", systemImage: "play.fill") {
            runOutput { await client.playToActiveOutput($0) }
        }.disabled(!hasOutput)
        Button("Speel hierna", systemImage: "text.line.first.and.arrowtriangle.forward") {
            run { records, zone in await client.queueTracks(records, next: true, zoneID: zone) }
        }.disabled(!hasZone)
        Button("Achteraan in wachtrij", systemImage: "text.append") {
            run { records, zone in await client.queueTracks(records, next: false, zoneID: zone) }
        }.disabled(!hasZone)
        Button("Speel geschud", systemImage: "shuffle") {
            runOutput { await client.playToActiveOutput($0.shuffled()) }
        }.disabled(!hasOutput)
        if let seed = trackRadioSeed {
            Divider()
            Button("Radio op dit nummer", systemImage: "dot.radiowaves.left.and.right") {
                guard let zone = client.selectedZone else { return }
                Haptics.tap()
                Task {
                    await client.startTrackRadio(title: seed.title, artist: seed.artist,
                                                 album: seed.album, zoneID: zone.id)
                }
            }.disabled(!hasZone)
            Menu("Start als DJ…", systemImage: "person.wave.2") {
                ForEach(DJMode.allCases, id: \.self) { mode in
                    Button(mode.title) {
                        guard let zone = client.selectedZone else { return }
                        Haptics.tap()
                        Task {
                            await client.startTrackRadio(title: seed.title, artist: seed.artist,
                                                         album: seed.album, zoneID: zone.id, djMode: mode)
                        }
                    }
                }
            }.disabled(!hasZone)
        }
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

    /// Like `run`, but output-agnostic — the action decides where playback goes
    /// (zone or this device) via `client.playToActiveOutput`.
    private func runOutput(_ action: @escaping (_ records: [TrackRecord]) async -> Void) {
        Haptics.tap()
        Task {
            let records = await fetch()
            guard !records.isEmpty else { return }
            await action(records)
        }
    }
}

extension DatabaseManager.LibraryTrackRow {
    /// The play/queue record for this library row.
    var asTrackRecord: TrackRecord {
        TrackRecord(id: id, title: title, artist: artist, album: album, year: year, isLive: isLive)
    }
}
