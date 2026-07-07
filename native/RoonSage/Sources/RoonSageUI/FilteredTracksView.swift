import RoonSageCore
import SwiftUI

/// What a browse tile filters the library by. Only `Hashable` primitives cross the
/// navigation boundary — `DatabaseManager.FilterOptions` is a mutable, non-Hashable
/// struct, so it is rebuilt inside `LibraryFilter.options` from these primitives.
public enum LibraryFilterKind: Hashable, Sendable {
    case genre(String)   // → FilterOptions.genres  (lowercased genre key)
    case tag(String)     // → FilterOptions.tags    (audio "sfeer" tag)
    case decade(Int)     // → FilterOptions.decades (e.g. 1980)
}

/// A navigable filter value used with `.navigationDestination(for: LibraryFilter.self)`.
/// Carries a display `title` captured at tap time (genre label / sfeer tag / "1980s").
public struct LibraryFilter: Hashable, Sendable {
    public let kind: LibraryFilterKind
    public let title: String

    public init(kind: LibraryFilterKind, title: String) {
        self.kind = kind
        self.title = title
    }

    /// Builds the fetch/play filter from the Hashable primitives.
    var options: DatabaseManager.FilterOptions {
        var opts = DatabaseManager.FilterOptions()
        switch kind {
        case .genre(let g):  opts.genres = [g]
        case .tag(let t):    opts.tags = [t]
        case .decade(let d): opts.decades = [d]
        }
        return opts
    }

    var icon: String {
        switch kind {
        case .genre:  "guitars.fill"
        case .tag:    "sparkles"
        case .decade: "calendar"
        }
    }
}

/// A filtered library list: every track matching a genre / sfeer-tag / decade, with a
/// Speel-alles / Shuffle / dit-apparaat header bar. Renders `TrackRecord` directly
/// (that's what `filterTracks` returns; `DatabaseManager.LibraryTrackRow`'s memberwise
/// init is internal to RoonSageCore, so it can't be constructed here — and filtered
/// results carry no BPM/Camelot to show anyway).
@MainActor
public struct FilteredTracksView: View {
    @Environment(RoonClient.self) private var client
    private let filter: LibraryFilter
    /// Page size for the infinite scroll — one genre/decade can span thousands of tracks.
    private let pageSize = 200
    /// Upper bound for "Speel alles" — a filtered set can be huge; don't queue it all.
    private let playAllCap = 500
    @State private var tracks: [TrackRecord] = []
    @State private var loaded = false
    @State private var loadingMore = false
    @State private var reachedEnd = false

    public init(filter: LibraryFilter) {
        self.filter = filter
    }

    public var body: some View {
        AsyncStateView(isLoading: !loaded, isEmpty: tracks.isEmpty,
                       onRetry: { loaded = false; reachedEnd = false; Task { await load() } }) {
            List {
                headerBar.plainCardRow()
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    FilteredTrackRow(track: track, canPlay: client.hasActiveOutput) {
                        Haptics.tap()
                        Task { await client.playToActiveOutput([track]) }
                    }
                    .contextMenu {
                        PlayActionsMenu(fetch: { [track] }, trackRadioSeed: track)
                    }
                    .onAppear {
                        // Prefetch the next page a few rows before the end → endless scroll.
                        if index >= tracks.count - 8 { Task { await loadMore() } }
                    }
                }
                if loadingMore {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .plainCardRow()
                }
            }
            .listStyle(.plain)
        } empty: {
            ContentUnavailableView("Geen tracks", systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Geen tracks voor “\(filter.title)”."))
        }
        .navigationTitle(filter.title)
        .task { await load() }
    }

    private var headerBar: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                Haptics.tap()
                Task {
                    // Play the whole filtered set (up to a queue-sane cap), not just
                    // the pages scrolled into view.
                    var opts = filter.options
                    opts.limit = playAllCap
                    let all = await client.filterTracks(options: opts)
                    await client.playToActiveOutput(all)
                }
            } label: { Label("Speel alles", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!client.hasActiveOutput || tracks.isEmpty)

            Button {
                guard let zone = client.selectedZone else { return }
                Haptics.tap()
                Task { await client.playShuffledMix(options: filter.options, count: 40, zoneID: zone.id) }
            } label: { Label("Shuffle", systemImage: "shuffle") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(client.selectedZone == nil)

            LocalPlayButton(style: .labeled, tracks: { tracks })
                .buttonStyle(.bordered)
                .controlSize(.small)

            Spacer(minLength: Spacing.sm)
            Text(reachedEnd ? "\(tracks.count)" : "\(tracks.count)+")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Spacing.xs)
    }

    private func pageOptions(offset: Int) -> DatabaseManager.FilterOptions {
        var opts = filter.options
        opts.limit = pageSize
        opts.offset = offset
        return opts
    }

    private func load() async {
        guard !loaded else { return }
        let page = await client.filterTracks(options: pageOptions(offset: 0))
        tracks = page
        reachedEnd = page.count < pageSize
        loaded = true
    }

    private func loadMore() async {
        guard loaded, !loadingMore, !reachedEnd else { return }
        loadingMore = true
        let page = await client.filterTracks(options: pageOptions(offset: tracks.count))
        tracks.append(contentsOf: page)
        if page.count < pageSize { reachedEnd = true }
        loadingMore = false
    }
}

/// Compact library row for a `TrackRecord` (art · title/live/year · artist · play).
struct FilteredTrackRow: View {
    let track: TrackRecord
    let canPlay: Bool
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AlbumArtView(imageKey: track.imageKey, size: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(track.title).font(.body).lineLimit(1)
                    if track.isLive {
                        Text("LIVE").font(.caption2.bold()).foregroundStyle(Color.roonWarning)
                    }
                    if let y = track.year {
                        Text(String(y)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if let a = track.artist {
                    Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel([track.title, track.artist].compactMap { $0 }.joined(separator: ", "))
            Spacer()
            Button(action: onPlay) { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .disabled(!canPlay)
                .accessibilityLabel("Speel nu")
        }
        .padding(.vertical, 2)
    }
}
