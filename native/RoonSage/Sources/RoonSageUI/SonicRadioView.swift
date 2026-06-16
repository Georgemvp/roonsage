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

    // AI artist radios → Qobuz
    @State private var qobuzRadios: [RoonClient.SonicRadioPlaylist] = []
    @State private var isLoadingQobuz = false
    @State private var qobuzLoaded = false
    @State private var isSyncing = false
    @State private var syncMessage: String?

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

                Divider().padding(.vertical, Spacing.sm)

                qobuzSection
            }
            .padding(Spacing.lg)
        }
        .navigationTitle("Radio's")
        .toolbar {
            Button {
                Task { await load(force: true); await loadQobuz(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Ververs de radio's van vandaag")
        }
        .task { await load(force: false) }
        .task { await loadQobuz(force: false) }
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

    // MARK: AI artist radios → Qobuz

    private var llmConfigured: Bool {
        let c = LLMConfigStore.load()
        return c.provider == .ollama || !c.apiKey.isEmpty
    }

    @ViewBuilder
    private var qobuzSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label {
                    Text("AI-radio's op Qobuz").font(.headline)
                } icon: {
                    Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.roonGold)
                }
                Text("Zes artiesten-radio's met een AI-titel + beschrijving, als Qobuz-playlists die continu worden ververst.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !client.qobuzConfigured {
                warningRow("Qobuz is niet ingesteld — voeg je inloggegevens toe bij Instellingen om te kunnen synchroniseren.")
            }
            if !llmConfigured {
                warningRow("Geen LLM ingesteld — radio's krijgen nette standaardtitels in plaats van AI-titels.")
            }

            HStack(spacing: Spacing.md) {
                Button {
                    Task { await sync() }
                } label: {
                    Label(isSyncing ? "Synchroniseren…" : "Sync alle radio's naar Qobuz",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.roonGold)
                .disabled(isSyncing || !client.qobuzConfigured)

                if isSyncing { ProgressView().controlSize(.small) }
            }

            if let syncMessage {
                Text(syncMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !qobuzRadios.isEmpty {
                LazyVGrid(columns: columns, spacing: Spacing.md) {
                    ForEach(qobuzRadios) { qobuzCard($0) }
                }
            } else if isLoadingQobuz {
                ProgressView().frame(maxWidth: .infinity).padding(.top, Spacing.md)
            } else if qobuzLoaded {
                Text("Nog geen AI-radio's — zorg dat je bibliotheek geanalyseerd is.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func warningRow(_ text: String) -> some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.roonDanger)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.roonDanger.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.md))
    }

    private func qobuzCard(_ radio: RoonClient.SonicRadioPlaylist) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ZStack(alignment: .topTrailing) {
                AlbumArtView(imageKey: radio.imageKey, size: 150, cornerRadius: Radius.lg)
                if radio.qobuzPlaylistID != nil {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.roonGold)
                        .shadow(radius: 3)
                        .padding(Spacing.sm)
                }
            }
            Text(radio.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text(radio.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Text("\(radio.artist) · \(radio.tracks.count) tracks · \(radio.qobuzPlaylistID != nil ? "op Qobuz" : "nog niet gesynct")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.sm)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    private func loadQobuz(force: Bool) async {
        guard force || !qobuzLoaded else { return }
        isLoadingQobuz = true
        defer { isLoadingQobuz = false; qobuzLoaded = true }
        qobuzRadios = await client.buildArtistRadioPlaylists()
    }

    private func sync() async {
        guard !isSyncing else { return }
        Haptics.tap()
        isSyncing = true
        syncMessage = nil
        defer { isSyncing = false }
        let count = await client.syncArtistRadiosToQobuz()
        // Re-read so cards reflect their new "op Qobuz" status.
        qobuzRadios = await client.buildArtistRadioPlaylists()
        qobuzLoaded = true
        if count > 0 {
            syncMessage = "\(count) radio('s) gesynchroniseerd naar Qobuz."
        } else if !client.qobuzConfigured {
            syncMessage = "Qobuz is niet ingesteld — vul je inloggegevens in bij Instellingen."
        } else if qobuzRadios.isEmpty {
            syncMessage = "Nog geen radio's om te synchroniseren — luister wat muziek en zorg dat je bibliotheek geanalyseerd is."
        } else {
            syncMessage = "Synchroniseren mislukt — controleer je Qobuz-instellingen."
        }
    }
}
