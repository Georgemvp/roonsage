import RoonSageCore
import SwiftUI

/// "Sonic Journeys" — the three Plexamp-style station types, renamed:
///   • Album Radio  — an endless station around an album (started from the album screen)
///   • Time Machine — a chronological journey old → new through your library
///   • The Bridge   — an A→B path between two tracks (reuses Song Paths)
///
/// Built on `List` + `.plainCardRow()` like `SonicRadioView`/`DJModesView`.
@MainActor
public struct SonicJourneysView: View {
    @Environment(RoonClient.self) private var client

    @State private var count = 40
    @State private var building = false
    @State private var syncing = false
    @State private var message: String?

    public init() {}

    public var body: some View {
        List {
            ZoneHintBanner().plainCardRow()
            header.plainCardRow()
            albumSection.plainCardRow()
            timeMachineSection.plainCardRow()
            bridgeSection.plainCardRow()
        }
        .navigationTitle("Sonic Journeys")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label {
                Text("Sonic Journeys").font(.headline)
            } icon: {
                Image(systemName: "map").foregroundStyle(Color.roonGold)
            }
            Text("Sonische reizen door je bibliotheek — rond een album, door de tijd, of van het ene naar het andere nummer.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Album Radio (started from the album screen)

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("Album Radio", systemImage: "square.stack")
                .font(.subheadline.weight(.semibold))
            Text("Open een album in je bibliotheek en tik op het radio-icoon — je krijgt een eindeloze radio die rond dat album blijft hangen en er sonisch verwante muziek bij zoekt.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    // MARK: Time Machine (chronological journey)

    private var timeMachineSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label("Time Machine", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
            Text("Een reis door de tijd: van oud naar nieuw, dwars door je bibliotheek. Jaartallen komen uit je bestandstags — muziek zonder jaartal doet niet mee.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper("Lengte: \(count) tracks", value: $count, in: 20...80, step: 10)
                .font(.caption)
            HStack(spacing: Spacing.sm) {
                Button {
                    startTimeMachine()
                } label: {
                    Label(building ? "Bezig…" : "Start reis", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.roonGold)
                .disabled(building || client.selectedZone == nil)

                if client.qobuzConfigured {
                    Button {
                        syncTimeMachine()
                    } label: {
                        Label(syncing ? "Synchroniseren…" : "Sync naar Qobuz",
                              systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(syncing)
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private func startTimeMachine() {
        guard let zone = client.selectedZone else { return }
        Haptics.tap()
        Task {
            building = true
            defer { building = false }
            let tracks = await client.buildTimeMachine(count: count)
            guard !tracks.isEmpty else {
                message = "Geen tracks met een jaartal gevonden — tag of analyseer eerst meer muziek."
                return
            }
            await client.curateTracks(tracks, zoneID: zone.id)
            message = "Tijdreis gestart — \(tracks.count) tracks van oud naar nieuw."
        }
    }

    private func syncTimeMachine() {
        Haptics.tap()
        Task {
            syncing = true
            defer { syncing = false }
            let tracks = await client.buildTimeMachine(count: count)
            guard !tracks.isEmpty else {
                message = "Geen tracks met een jaartal gevonden om te synchroniseren."
                return
            }
            let ok = await client.syncJourneyToQobuz(
                title: "Time Machine",
                description: "Een reis van oud naar nieuw, samengesteld in RoonSage.",
                tracks: tracks)
            message = ok
                ? "Op Qobuz gezet als ‘\(RoonClient.qobuzPlaylistName(for: "Time Machine"))’."
                : "Sync naar Qobuz mislukt — controleer je Qobuz-instellingen."
        }
    }

    // MARK: The Bridge (A→B)

    private var bridgeSection: some View {
        NavigationLink {
            SongPathsView()
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.title3)
                    .foregroundStyle(Color.roonGold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("The Bridge").font(.subheadline.weight(.semibold))
                    Text("Kies een start- en eindnummer; RoonSage bouwt de soepele sonische brug ertussen — en zet 'm desgewenst op Qobuz.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle()
    }
}
