import SwiftUI
import RoonSageCore

// MARK: - Ontdekkingen (outward-facing discovery feed)
//
// Renders the discovery engine's ranked recommendations — artists/albums you
// don't own yet, resolved to Qobuz — as accept/play/reject cards. The server
// builds the feed daily; this view fetches it and posts actions. Built on List +
// .plainCardRow() (the iOS-26-safe pattern), like DiscoveryView.

@MainActor
public struct DiscoverFeedView: View {
    @Environment(RoonClient.self) private var client

    @State private var items: [RecommendationItemDTO] = []
    @State private var loading = true
    @State private var refreshing = false
    @State private var kind: KindFilter = .all
    @State private var acted = Set<Int64>()   // optimistic hide after accept/reject

    enum KindFilter: String, CaseIterable, Identifiable {
        case all, artist, album
        var id: String { rawValue }
        var label: String { switch self { case .all: "Alles"; case .artist: "Artiesten"; case .album: "Albums" } }
        var kind: RecommendationKind? { switch self { case .all: nil; case .artist: .artist; case .album: .album } }
    }

    public init() {}

    private var visible: [RecommendationItemDTO] {
        items.filter { !acted.contains($0.id) }
             .filter { kind.kind == nil || $0.kind == kind.kind }
    }

    public var body: some View {
        Group {
            if loading {
                ProgressView("Ontdekkingen laden…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                emptyState
            } else {
                List {
                    Picker("Soort", selection: $kind) {
                        ForEach(KindFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .plainCardRow()

                    ForEach(visible) { item in
                        RecommendationCard(
                            item: item,
                            onAccept: { accept(item) },
                            onPlay: { play(item) },
                            onReject: { reject(item) })
                        .plainCardRow()
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Ontdekkingen")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(refreshing)
                .help("Nieuwe ontdekkingen bouwen")
                .accessibilityLabel("Ververs ontdekkingen")
            }
        }
        .task { await load() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nog geen ontdekkingen", systemImage: "wand.and.stars.inverse")
        } description: {
            Text(refreshing
                 ? "De server bouwt een nieuwe set — dit kan even duren."
                 : "De server bouwt dagelijks een verse set aanbevelingen op basis van je smaak.")
        } actions: {
            Button { Task { await refresh() } } label: {
                Label(refreshing ? "Bezig…" : "Ververs", systemImage: "arrow.clockwise")
            }
            .disabled(refreshing)
        }
    }

    // MARK: - Data

    private func load() async {
        loading = true
        items = await client.discoveryRecommendations(limit: 60)
        loading = false
    }

    /// Trigger a server run, then poll status until it completes (bounded), and
    /// reload. Falls back to a plain reload if the run doesn't report progress.
    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await client.triggerDiscoveryRun()
        // Poll up to ~2 minutes for the batch to finish (MB resolve is slow).
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            let status = await client.discoveryRunStatus()
            if status.status != "running" && status.itemCount > 0 { break }
        }
        acted.removeAll()
        items = await client.discoveryRecommendations(limit: 60)
    }

    // MARK: - Actions

    private func accept(_ item: RecommendationItemDTO) {
        Haptics.success()
        withAnimation { _ = acted.insert(item.id) }
        Task { await client.acceptRecommendation(item.id) }
    }

    private func play(_ item: RecommendationItemDTO) {
        Haptics.tap()
        Task { await client.playRecommendation(item.id, zoneID: client.selectedZone?.id) }
    }

    private func reject(_ item: RecommendationItemDTO) {
        Haptics.tap()
        withAnimation { _ = acted.insert(item.id) }
        Task { await client.rejectRecommendation(item.id, permanent: false) }
    }
}

// MARK: - Card

@MainActor
private struct RecommendationCard: View {
    let item: RecommendationItemDTO
    let onAccept: () -> Void
    let onPlay: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            artwork
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(item.album ?? item.artist)
                    .font(.headline)
                    .lineLimit(2)
                if item.album != nil {
                    Text(item.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }

                HStack(spacing: Spacing.sm) {
                    Badge("\(Int((item.score * 100).rounded()))%", tint: scoreTint)
                    if let y = item.year { Badge(String(y)) }
                    ForEach(sourceLabels, id: \.self) { Badge($0, tint: .roonInfo) }
                }

                if let why = item.explanation, !why.isEmpty {
                    Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if item.kind == .album, (item.qobuzAlbumID ?? "").isEmpty {
                    Text("Niet op Qobuz gevonden").font(.caption2).foregroundStyle(.secondary)
                }

                actionRow
            }
        }
        .cardStyle()
    }

    private var actionRow: some View {
        HStack(spacing: Spacing.sm) {
            Button(action: onAccept) {
                Label(item.kind == .album ? "Bewaar" : "Volg", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button(action: onPlay) {
                Label("Speel", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            Button(action: onReject) {
                Image(systemName: "hand.thumbsdown")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Afwijzen")
            .help("Afwijzen — even niet meer tonen")
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var artwork: some View {
        let size: CGFloat = 64
        if let s = item.imageURL, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                default: placeholder
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        } else {
            placeholder.frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: Radius.md)
            .fill(.background.tertiary)
            .overlay {
                Image(systemName: item.kind == .album ? "opticaldisc" : "music.mic")
                    .foregroundStyle(.secondary)
            }
    }

    private var scoreTint: Color {
        if item.score >= 0.6 { return .roonSuccess }
        if item.score >= 0.45 { return .roonWarning }
        return .secondary
    }

    /// Short NL labels for the producers that surfaced this recommendation.
    private var sourceLabels: [String] {
        var seen = Set<String>(), out: [String] = []
        for s in item.sources {
            let label = Self.producerLabel(s.producer)
            if seen.insert(label).inserted { out.append(label) }
        }
        return out
    }

    private static func producerLabel(_ id: String) -> String {
        switch id {
        case "similar-artist-web":   "Vergelijkbaar"
        case "charts":               "Charts"
        case "release-radar":        "Nieuw"
        case "gap-fill":             "Aanvulling"
        case "artist-relationships": "Samenwerking"
        case "listenbrainz-radio":   "ListenBrainz"
        case "ai-picks":             "AI"
        default:                     id
        }
    }
}
