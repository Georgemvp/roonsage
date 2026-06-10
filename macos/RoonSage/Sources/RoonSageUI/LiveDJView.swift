import RoonSageCore
import SwiftUI

/// Live DJ mode — while a track plays, surface the library tracks that mix into
/// it best right now (Camelot-harmonic + tempo-matched), each with one-tap
/// "play now" or "queue next". Built on the synced analyzer audio features.
@MainActor
public struct LiveDJView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    @State private var suggestions: [DatabaseManager.DJCandidate] = []
    @State private var currentBPM: Double = 0
    @State private var currentCamelot: String = ""
    @State private var loading = false
    @State private var hasFeatures = true

    public var body: some View {
        Group {
            if let zone = client.selectedZone, let np = zone.nowPlaying {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        currentCard(np)
                        Divider()
                        header
                        if loading && suggestions.isEmpty {
                            SkeletonRows(count: 8)
                        } else if !hasFeatures {
                            noFeaturesNote
                        } else if suggestions.isEmpty {
                            Text("Geen compatibele tracks gevonden in dit tempo.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            ForEach(suggestions, id: \.id) { row($0, zoneID: zone.id) }
                        }
                    }
                    .padding()
                }
                .task(id: np.title) { await reload(np) }
            } else {
                ContentUnavailableView("Niets aan het spelen",
                    systemImage: "slider.horizontal.2.gobackward",
                    description: Text("Start een track in een zone om harmonische vervolgsuggesties te zien."))
            }
        }
        .navigationTitle("Live DJ")
    }

    // MARK: Now-playing card

    private func currentCard(_ np: NowPlaying) -> some View {
        HStack(spacing: Spacing.md) {
            AlbumArtView(imageKey: np.imageKey, size: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nu spelend").font(.caption).foregroundStyle(.secondary)
                Text(np.title).font(.headline).lineLimit(1)
                if let artist = np.artist {
                    Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: Spacing.sm) {
                    if currentBPM > 0 { Badge("\(Int(currentBPM)) BPM") }
                    if !currentCamelot.isEmpty { Badge(currentCamelot, tint: .roonGold) }
                }
                .padding(.top, 2)
            }
            Spacer()
        }
    }

    private var header: some View {
        HStack {
            Text("Mixt hierna goed").font(.headline)
            Spacer()
            if loading { ProgressView().controlSize(.small) }
        }
    }

    private var noFeaturesNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Geen audio-kenmerken voor deze track", systemImage: "waveform.slash")
                .font(.callout)
            Text("Synchroniseer audio-kenmerken (Instellingen → Audio Analyzer) om harmonische suggesties te krijgen.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: Suggestion row

    private func row(_ c: DatabaseManager.DJCandidate, zoneID: String) -> some View {
        let relation = RoonClient.harmonicRelation(current: currentCamelot, candidate: c.camelot)
        return HStack(spacing: Spacing.md) {
            AlbumArtView(imageKey: c.imageKey, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.callout).lineLimit(1)
                if let artist = c.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: Spacing.xs) {
                    Badge("\(Int(c.bpm)) BPM")
                    if !c.camelot.isEmpty { Badge(c.camelot) }
                    relationBadge(relation)
                }
            }
            Spacer()
            Button {
                Task { await client.queueTracks([asRecord(c)], next: true, zoneID: zoneID) }
            } label: { Image(systemName: "text.line.first.and.arrowtriangle.forward") }
                .buttonStyle(.borderless).help("Als volgende in wachtrij")
            Button {
                Task { await client.curateTracks([asRecord(c)], zoneID: zoneID) }
            } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless).help("Speel nu")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func relationBadge(_ relation: RoonClient.HarmonicRelation) -> some View {
        switch relation {
        case .harmonic: Badge("Harmonisch", tint: .roonGold)
        case .sameKey:  Badge("Zelfde toon", tint: .green)
        case .tempo:    EmptyView()
        }
    }

    // MARK: Data

    private func asRecord(_ c: DatabaseManager.DJCandidate) -> TrackRecord {
        TrackRecord(id: c.id, title: c.title, artist: c.artist, album: c.album)
    }

    private func reload(_ np: NowPlaying) async {
        loading = true
        defer { loading = false }
        guard let feat = client.featuresFor(title: np.title, artist: np.artist, album: np.album),
              feat.bpm > 0 else {
            hasFeatures = false
            currentBPM = 0; currentCamelot = ""; suggestions = []
            return
        }
        hasFeatures = true
        currentBPM = feat.bpm
        currentCamelot = feat.camelot
        suggestions = await client.harmonicNextTracks(bpm: feat.bpm, camelot: feat.camelot, limit: 30)
    }
}
