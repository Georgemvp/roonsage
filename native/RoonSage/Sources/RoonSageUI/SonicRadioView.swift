import RoonSageCore
import SwiftUI

/// Daily "for you" stations seeded from the artists you play most. Each card
/// starts an endless sonic radio that refills itself as it drains.
@MainActor
public struct SonicRadioView: View {
    @Environment(RoonClient.self) private var client
    @State private var radios: [RoonClient.SonicRadio] = []
    @State private var isLoading = false
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.md)]

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if let radio = client.activeRadio { activeBanner(radio) }

                header

                if !radios.isEmpty {
                    LazyVGrid(columns: columns, spacing: Spacing.md) {
                        ForEach(radios) { radioCard($0) }
                    }
                } else if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, Spacing.xl)
                } else if loaded {
                    emptyState
                }
            }
            .padding(Spacing.lg)
        }
        .navigationTitle("Radio's")
        .toolbar {
            Button {
                Task { await load(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Ververs de radio's van vandaag")
        }
        .task { await load(force: false) }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label {
                Text("Sonische radio's").font(.headline)
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Color.roonGold)
            }
            Text("Elke dag verse, eindeloze stations rond de artiesten die je het meest luistert.")
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

    private func radioCard(_ radio: RoonClient.SonicRadio) -> some View {
        Button {
            start(radio)
        } label: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ZStack(alignment: .bottomTrailing) {
                    AlbumArtView(imageKey: radio.imageKey, size: 150, cornerRadius: Radius.lg)
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.roonGold)
                        .shadow(radius: 3)
                        .padding(Spacing.sm)
                }
                Text(radio.artist)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("Sonische radio · \(radio.trackCount) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(client.selectedZone == nil)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.largeTitle).foregroundStyle(.tertiary)
            Text("Nog geen radio's")
                .font(.headline)
            Text("Luister wat muziek en zorg dat je bibliotheek geanalyseerd is — dan verschijnen hier dagelijks stations rond je favoriete artiesten.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xl)
    }

    // MARK: Actions

    private func start(_ radio: RoonClient.SonicRadio) {
        guard let zone = client.selectedZone else { return }
        Haptics.tap()
        Task { await client.startRadio(radio, zoneID: zone.id) }
    }

    private func load(force: Bool) async {
        guard force || !loaded else { return }
        isLoading = true
        defer { isLoading = false; loaded = true }
        radios = await client.dailyRadios()
    }
}
