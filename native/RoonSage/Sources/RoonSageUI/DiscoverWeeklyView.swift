import RoonSageCore
import SwiftUI

/// "Ontdek Wekelijks" — the library-first weekly discovery playlist. A hub instap
/// showing the current week's selection (AI title + description + generation date),
/// its tracklist (with a clear "nog niet in je bibliotheek" flag on Qobuz/
/// ListenBrainz enrichment picks), a "Speel nu" action, and a manual "Ververs nu".
///
/// The server builds and stores it; this view just fetches it (`client.discoverWeekly`)
/// and can ask the server to rebuild (`client.refreshDiscoverWeekly`). Shared by
/// macOS + iOS — no platform chrome.
@MainActor
public struct DiscoverWeeklyView: View {
    @Environment(RoonClient.self) private var client

    @State private var playlist: DiscoverWeeklyPlaylist?
    @State private var loading = true
    @State private var refreshing = false

    public init() {}

    public var body: some View {
        List {
            ZoneHintBanner().plainCardRow()
            if let pl = playlist {
                header(pl).plainCardRow()
                tracksSection(pl)
            } else if loading {
                loadingState.plainCardRow()
            } else {
                emptyState.plainCardRow()
            }
        }
        .navigationTitle("Ontdek Wekelijks")
        .toolbar {
            Button {
                Task { await refreshNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(refreshing)
            .help("Ververs de wekelijkse selectie nu")
        }
        .task { await load() }
    }

    // MARK: Header card

    private func header(_ pl: DiscoverWeeklyPlaylist) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top, spacing: Spacing.md) {
                AlbumArtView(imageKey: pl.imageKey, size: 96, cornerRadius: Radius.lg)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(pl.title)
                        .font(.title3).bold()
                        .fixedSize(horizontal: false, vertical: true)
                    Text(pl.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle(pl))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: Spacing.sm) {
                Button {
                    Haptics.tap()
                    guard let z = client.selectedZone?.id else { return }
                    Task { await client.curateTracks(pl.trackRecords, zoneID: z) }
                } label: {
                    Label("Speel nu", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(client.selectedZone == nil)

                Button {
                    Task { await refreshNow() }
                } label: {
                    if refreshing {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else {
                        Label("Ververs nu", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(refreshing)
            }
        }
        .padding(Spacing.md)
    }

    // MARK: Tracks

    private func tracksSection(_ pl: DiscoverWeeklyPlaylist) -> some View {
        Section("Tracks") {
            ForEach(Array(pl.tracks.enumerated()), id: \.offset) { idx, t in
                HStack(spacing: Spacing.md) {
                    Text("\(idx + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.body).lineLimit(1)
                        Text(t.artist ?? "Onbekend")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if t.notInLibrary {
                        Text("nog niet in je bibliotheek")
                            .font(.caption2)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.roonGold.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.roonGold)
                    }
                }
            }
        }
    }

    // MARK: States

    private var loadingState: some View {
        HStack { Spacer(); ProgressView("Ontdek Wekelijks laden…"); Spacer() }
            .padding(.vertical, Spacing.xl)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "sparkles")
                .font(.largeTitle).foregroundStyle(Color.roonGold)
            Text("Nog geen wekelijkse ontdek-playlist")
                .font(.headline)
            Text("De server bouwt hem automatisch, of tik hieronder om hem nu te genereren. Hiervoor is een geanalyseerde bibliotheek en wat luistergeschiedenis nodig.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await refreshNow() }
            } label: {
                if refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Genereer nu", systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(refreshing)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
    }

    // MARK: Data

    private func load() async {
        loading = true
        playlist = await client.discoverWeekly()
        loading = false
    }

    private func refreshNow() async {
        guard !refreshing else { return }
        refreshing = true
        if let fresh = await client.refreshDiscoverWeekly() {
            playlist = fresh
        }
        refreshing = false
    }

    // MARK: Formatting

    private func subtitle(_ pl: DiscoverWeeklyPlaylist) -> String {
        var parts: [String] = []
        if let date = Self.isoParser.date(from: pl.generatedAt) {
            parts.append("Gegenereerd op \(Self.dateFormatter.string(from: date))")
        } else if !pl.weekKey.isEmpty {
            parts.append("Week \(pl.weekKey)")
        }
        parts.append("\(pl.tracks.count) tracks")
        if pl.discoveryCount > 0 { parts.append("\(pl.discoveryCount) buiten je bibliotheek") }
        return parts.joined(separator: " · ")
    }

    private static let isoParser = ISO8601DateFormatter()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
