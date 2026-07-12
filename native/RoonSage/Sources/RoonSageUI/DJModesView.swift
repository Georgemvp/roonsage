import RoonSageCore
import SwiftUI

/// Guest-DJ personas — the Plexamp-style "Guest DJ" idea, renamed. Pick a persona
/// and it takes over what plays next from the track you're on (an endless station
/// seeded on the current track, shaped by that persona's dial/arc/gate). The
/// "Guest DJ · Autoplay" section makes one persona persistent: when normal
/// playback runs dry it's topped up automatically.
///
/// Built on `List` + `.plainCardRow()` like `SonicRadioView` (see `GenerateView`
/// for why not a custom ScrollView). Persona names/blurbs are English by design;
/// the surrounding chrome stays Dutch like the rest of the app.
@MainActor
public struct DJModesView: View {
    @Environment(RoonClient.self) private var client

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: Spacing.md)]

    public init() {}

    public var body: some View {
        @Bindable var client = client
        List {
            if let radio = client.activeRadio { activeBanner(radio).plainCardRow() }

            ZoneHintBanner().plainCardRow()

            header.plainCardRow()

            // Guest DJ · Autoplay — one persona steers everything.
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Label("Guest DJ · Autoplay", systemImage: "person.wave.2.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                Text("Laat de DJ automatisch overnemen wanneer je wachtrij bijna leeg is — hij bouwt eindeloos verder op het nummer dat speelt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(isOn: $client.djAutoplayEnabled) {
                    Text("Autoplay via de gekozen DJ").font(.caption)
                }
                .toggleStyle(.switch)
                Picker("DJ", selection: $client.selectedDJMode) {
                    ForEach(DJMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                Text(client.selectedDJMode.blurb)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .cardStyle()
            .plainCardRow()

            if !canStart {
                Text("Speel eerst een nummer op de gekozen zone — een DJ start op wat er nú speelt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .plainCardRow()
            }

            LazyVGrid(columns: columns, spacing: Spacing.md) {
                ForEach(DJMode.allCases, id: \.self) { personaCard($0) }
            }
            .plainCardRow()
        }
        .navigationTitle("DJ-modi")
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label {
                Text("DJ-modi").font(.headline)
            } icon: {
                Image(systemName: "person.wave.2").foregroundStyle(Color.roonGold)
            }
            Text("Kies een DJ met een eigen specialiteit — dichtbij blijven, op avontuur, dezelfde artiest, hetzelfde tijdperk of de stemming vasthouden.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func activeBanner(_ radio: RoonClient.RadioStatus) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(Color.roonGold)
            VStack(alignment: .leading, spacing: 2) {
                Text("Radio speelt").font(.caption).foregroundStyle(.secondary)
                Text(radio.artist).font(.headline)
            }
            Spacer()
            Button(role: .destructive) {
                Haptics.tap()
                client.stopRadio()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
        }
        .cardStyle()
    }

    private func personaCard(_ mode: DJMode) -> some View {
        Button {
            start(mode)
        } label: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Image(systemName: mode.symbol)
                        .font(.title2)
                        .foregroundStyle(Color.roonGold)
                    Spacer()
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.roonGold)
                }
                Text(mode.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(mode.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.sm)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
            .contentShape(RoundedRectangle(cornerRadius: Radius.lg))
        }
        .buttonStyle(.plain)
        .disabled(!canStart)
    }

    // MARK: Actions

    /// A persona starts on whatever is playing on the selected zone.
    private var canStart: Bool { client.selectedZone?.nowPlaying != nil }

    private func start(_ mode: DJMode) {
        guard let zone = client.selectedZone, let np = zone.nowPlaying else { return }
        Haptics.tap()
        Task {
            await client.startTrackRadio(title: np.title, artist: np.artist,
                                         album: np.album, zoneID: zone.id, djMode: mode)
        }
    }
}
