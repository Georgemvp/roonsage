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
    @State private var errorText: String?
    @State private var kind: KindFilter = .all
    @State private var acted = Set<Int64>()   // optimistic hide after accept/reject
    @State private var undoItem: RecommendationItemDTO?   // last skipped, shown in the undo bar
    @State private var rejectTask: Task<Void, Never>?     // delayed reject POST — cancelling it IS the undo
    @State private var showInsights = false               // Ontdek-inzichten sheet

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
                ProgressView("Nieuwe Ontdekkingen laden…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText, items.isEmpty {
                ErrorStateView(errorText) { Task { await load() } }
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
                        // Native List swipes — the digarr gesture, but width-safe
                        // (a custom ZStack card-stack would re-trigger the iOS-26
                        // over-wide NavigationStack bug these views were rebuilt to
                        // dodge). Buttons stay for macOS / accessibility.
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { accept(item) } label: {
                                Label(item.kind == .album ? "Bewaar" : "Volg",
                                      systemImage: "plus.circle.fill")
                            }
                            .tint(.roonSuccess)
                        }
                        // Full-swipe fires the FIRST action (Overslaan). Safe now
                        // that a stray skip is recoverable via the undo bar; Speel
                        // stays as a revealed second button.
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button { reject(item) } label: {
                                Label("Overslaan", systemImage: "hand.thumbsdown")
                            }
                            .tint(.roonWarning)
                            Button { play(item) } label: {
                                Label("Speel", systemImage: "play.fill")
                            }
                            .tint(.roonInfo)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Nieuwe Ontdekkingen")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showInsights = true } label: {
                    Image(systemName: "chart.bar")
                }
                .help("Ontdek-inzichten")
                .accessibilityLabel("Ontdek-inzichten")
            }
            ToolbarItem(placement: .primaryAction) {
                // F12a: "iets als mijn smaak, maar [stemming]" — a one-off mood-
                // seeded run. Disabled while any run is in flight, same as Ververs.
                Menu {
                    ForEach(RoonClient.knownMoodKeys, id: \.self) { key in
                        Button(RoonClient.moodLabel(key)) { Task { await refresh(mood: key) } }
                    }
                } label: {
                    Image(systemName: "theatermasks")
                }
                .disabled(refreshing)
                .help("Ontdek op stemming")
                .accessibilityLabel("Ontdek op stemming")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(refreshing)
                .help("Nieuwe ontdekkingen bouwen")
                .accessibilityLabel("Ververs ontdekkingen")
            }
        }
        .ambientSurface()
        .task { await load() }
        .overlay(alignment: .bottom) { undoBanner }
        .onDisappear { commitPendingRejectNow() }
        .sheet(isPresented: $showInsights) {
            NavigationStack {
                DiscoverInsightsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Klaar") { showInsights = false }
                        }
                    }
            }
        }
    }

    /// Floating "undo skip" bar. Present while a reject is still within its
    /// cancellation window — tapping it restores the card and cancels the POST.
    @ViewBuilder private var undoBanner: some View {
        if let item = undoItem {
            HStack(spacing: Spacing.md) {
                Image(systemName: "hand.thumbsdown")
                    .foregroundStyle(.secondary)
                Text("\(item.album ?? item.artist) overgeslagen")
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: Spacing.md)
                Button("Ongedaan maken") { undoReject() }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.roonGold)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(color: .roonShadow, radius: 8, y: 2)
            .padding(.horizontal, Spacing.lg)
            .padding(.bottom, Spacing.sm)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nog geen ontdekkingen", systemImage: "wand.and.stars.inverse")
        } description: {
            Text(refreshing
                 ? "De server bouwt een nieuwe set — dit kan even duren."
                 : "Nieuwe Ontdekkingen zoekt artiesten en albums búiten je bibliotheek, op basis van je smaak en meteen speelbaar via Qobuz. (Ontdek Wekelijks put juist uit wat je al hebt.) De server bouwt dagelijks een verse set — veeg om te bewaren of over te slaan.")
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
        errorText = nil
        do { items = try await client.discoveryRecommendationsChecked(limit: 60) }
        catch { errorText = error.localizedDescription }
        loading = false
    }

    /// Trigger a server run, then poll status until it completes (bounded), and
    /// reload. Falls back to a plain reload if the run doesn't report progress.
    /// `mood` (F12a): a raw CLAP mood key from `RoonClient.knownMoodKeys`, or nil
    /// for the ordinary taste-based refresh.
    private func refresh(mood: String? = nil) async {
        guard !refreshing else { return }
        commitPendingRejectNow()   // don't let a reload resurrect an in-flight skip
        refreshing = true
        defer { refreshing = false }
        await client.triggerDiscoveryRun(mood: mood)
        // Poll up to ~2 minutes for the batch to finish (MB resolve is slow).
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            let status = await client.discoveryRunStatus()
            if status.status != "running" && status.itemCount > 0 { break }
        }
        acted.removeAll()
        errorText = nil
        do { items = try await client.discoveryRecommendationsChecked(limit: 60) }
        catch { errorText = error.localizedDescription }
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

    /// Optimistically hide the card, then POST the reject after a short grace
    /// window so the undo bar can cancel it. Only one skip is "in flight" at a
    /// time — a new skip commits the previous one first.
    private func reject(_ item: RecommendationItemDTO) {
        Haptics.tap()
        commitPendingRejectNow()
        withAnimation(Motion.quick) {
            _ = acted.insert(item.id)
            undoItem = item
        }
        rejectTask = Task {
            try? await Task.sleep(for: .seconds(4.5))
            if Task.isCancelled { return }
            await client.rejectRecommendation(item.id, permanent: false)
            if undoItem?.id == item.id {
                withAnimation(Motion.quick) { undoItem = nil }
            }
        }
    }

    /// Cancel the pending POST and bring the card back.
    private func undoReject() {
        guard let item = undoItem else { return }
        Haptics.tap()
        rejectTask?.cancel(); rejectTask = nil
        withAnimation(Motion.quick) {
            _ = acted.remove(item.id)
            undoItem = nil
        }
    }

    /// Flush an in-flight skip immediately (on a new skip, refresh, or leaving
    /// the view) so a pending reject is never silently dropped.
    private func commitPendingRejectNow() {
        guard let item = undoItem else { return }
        rejectTask?.cancel(); rejectTask = nil
        undoItem = nil
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
        VStack(alignment: .leading, spacing: 0) {
            heroArt
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(item.album ?? item.artist)
                    .font(Typography.heading)
                    .lineLimit(2)
                if item.album != nil {
                    Text(item.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if item.year != nil || !sourceLabels.isEmpty {
                    HStack(spacing: Spacing.sm) {
                        if let y = item.year { Badge(String(y)) }
                        ForEach(sourceLabels, id: \.self) { Badge($0, tint: .roonInfo) }
                    }
                }

                if let why = item.explanation, !why.isEmpty {
                    Text(why)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.kind == .album, (item.qobuzAlbumID ?? "").isEmpty {
                    Label("Niet op Qobuz gevonden", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let c = item.components {
                    ScoreBreakdownView(components: c)
                        .padding(.top, Spacing.xs)
                }

                actionRow
                    .padding(.top, Spacing.xs)
            }
            .padding(Spacing.lg)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
    }

    /// Full-width hero banner: cached cover, a legibility scrim, and the total
    /// score as a chip — discovery is a visual act, so the art leads. A fixed
    /// container + overlaid image (rather than sizing the image directly) avoids
    /// the infinite-width proposal that makes an aspect-fill image lay out wrong.
    private var heroArt: some View {
        Rectangle()
            .fill(.background.tertiary)
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .overlay {
                CachedArtImage(url: item.imageURL.flatMap { URL(string: $0) }) {
                    heroPlaceholder
                }
            }
            .clipped()
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.35)],
                               startPoint: .center, endPoint: .bottom)
                    .frame(height: 60)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) { scoreChip }
    }

    private var heroPlaceholder: some View {
        Image(systemName: item.kind == .album ? "opticaldisc" : "music.mic")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
    }

    private var scoreChip: some View {
        Text("\(Int((item.score * 100).rounded()))%")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(scoreTint)
            .padding(Spacing.sm)
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
            .accessibilityLabel("Overslaan")
            .help("Overslaan — even niet meer tonen")
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

    private static func producerLabel(_ id: String) -> String { DiscoveryProducerLabel.nl(id) }
}

// MARK: - Score breakdown

/// The persisted `ScoreComponents` rendered as a compact equaliser so the feed
/// SHOWS why something scored as it did — the data was already stored in
/// `score_json`, just never surfaced. Bars are the raw per-signal strengths
/// (0…1: "how strong is each signal"), not the weighted contributions.
@MainActor
private struct ScoreBreakdownView: View {
    let components: ScoreComponents

    private var rows: [(label: String, value: Double)] {
        [("Consensus", components.consensus),
         ("Gelijkenis", components.similarity),
         ("Genre", components.genreOverlap),
         ("AI", components.aiConfidence),
         ("Feedback", components.feedbackBoost)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Score-opbouw")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.label) { row in
                HStack(spacing: Spacing.sm) {
                    Text(row.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 74, alignment: .leading)
                    ScoreBar(value: row.value)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Score-opbouw")
    }
}

/// One 0…1 bar. GeometryReader is constrained to 5 pt tall, so it reads the
/// row's (already width-clamped) content width for a proportional fill without
/// the greedy-sizing pitfalls of an unconstrained reader.
private struct ScoreBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.roonGold)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 5)
    }
}
