import RoonSageCore
import SwiftUI

/// "Recent" hub (muffon-style "Listened"): the last things you actually played,
/// pivotable between nummers / artiesten / albums. Reads the shared listen
/// snapshot (works in thin-client mode too — it pulls from the server), and
/// derives the distinct artist/album lists client-side, newest first. Tapping a
/// row replays it on the active output.
@MainActor
struct RecentView: View {
    @Environment(RoonClient.self) private var client

    private enum Pivot: String, CaseIterable, Identifiable {
        case tracks, artists, albums, onThisDay, timeMachine
        var id: String { rawValue }
        var label: String {
            switch self {
            case .tracks:      LS("recent.pivot.tracks")
            case .artists:     LS("recent.pivot.artists")
            case .albums:      LS("recent.pivot.albums")
            case .onThisDay:   LS("recent.pivot.onThisDay")
            case .timeMachine: LS("recent.pivot.timeMachine")
            }
        }
    }

    @State private var recent: [DatabaseManager.ListenEntry] = []
    @State private var onThisDay: [DatabaseManager.OnThisDayEntry] = []
    @State private var timeMachine: [DatabaseManager.TastePeriod] = []
    @State private var pivot: Pivot = .tracks
    @State private var loaded = false
    @State private var busy: String?

    /// Empty-state is per-pivot: "op deze dag" can be empty while recent isn't.
    private var currentIsEmpty: Bool {
        switch pivot {
        case .tracks, .artists, .albums: recent.isEmpty
        case .onThisDay:                 onThisDay.isEmpty
        case .timeMachine:               timeMachine.isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(LS("recent.pivotLabel"), selection: $pivot) {
                ForEach(Pivot.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(Spacing.md)

            AsyncStateView(isLoading: !loaded, isEmpty: currentIsEmpty) {
                content
            } empty: {
                ContentUnavailableView {
                    Label { LT("recent.empty.title") } icon: { Image(systemName: "clock.arrow.circlepath") }
                } description: {
                    LT("recent.empty.desc")
                }
            }
        }
        .navigationTitle(LS("nav.recent"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch pivot {
        case .tracks:
            List(Array(recent.enumerated()), id: \.offset) { _, e in
                row(kind: "track", title: e.title,
                    subtitle: [e.artist, e.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                    played: e.playedAt, artist: e.artist, album: e.album)
            }
        case .artists:
            List(distinctArtists, id: \.self) { name in
                row(kind: "artist", title: name, subtitle: nil, played: nil, artist: name, album: nil)
            }
        case .albums:
            List(distinctAlbums, id: \.id) { a in
                row(kind: "album", title: a.album, subtitle: a.artist, played: nil, artist: a.artist, album: nil)
            }
        case .onThisDay:
            List(Array(onThisDay.enumerated()), id: \.offset) { _, e in
                row(kind: "track", title: e.title,
                    subtitle: [e.artist, e.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                    played: e.playedAt, artist: e.artist, album: e.album)
            }
        case .timeMachine:
            List {
                ForEach(timeMachine, id: \.year) { period in
                    Section("\(String(period.year)) · \(period.totalPlays)×") {
                        ForEach(period.topArtists, id: \.artist) { a in
                            row(kind: "artist", title: a.artist, subtitle: "\(a.count)×",
                                played: nil, artist: a.artist, album: nil)
                        }
                    }
                }
            }
        }
    }

    private func row(kind: String, title: String, subtitle: String?, played: String?,
                     artist: String?, album: String?) -> some View {
        let key = "\(kind)|\(title)|\(artist ?? "")"
        return Button {
            play(kind: kind, title: title, artist: artist, album: album, key: key)
        } label: {
            HStack(spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if busy == key {
                    ProgressView().controlSize(.small)
                } else if let played, let when = relativeDate(played) {
                    Text(when).font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Image(systemName: "play.circle")
                        .foregroundStyle(client.hasActiveOutput ? Color.roonGold : .secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!client.hasActiveOutput)
    }

    // MARK: Distinct pivots (client-side, newest first)

    private var distinctArtists: [String] {
        var seen = Set<String>(), out: [String] = []
        for e in recent {
            guard let a = e.artist, !a.isEmpty else { continue }
            let k = a.lowercased()
            if seen.insert(k).inserted { out.append(a) }
            if out.count >= 80 { break }
        }
        return out
    }

    private struct AlbumRef: Identifiable { let album: String; let artist: String?; var id: String }
    private var distinctAlbums: [AlbumRef] {
        var seen = Set<String>(), out: [AlbumRef] = []
        for e in recent {
            guard let al = e.album, !al.isEmpty else { continue }
            let k = "\(al.lowercased())|\((e.artist ?? "").lowercased())"
            if seen.insert(k).inserted { out.append(AlbumRef(album: al, artist: e.artist, id: k)) }
            if out.count >= 80 { break }
        }
        return out
    }

    // MARK: Actions

    private func load() async {
        if let snap = await client.tasteProfile(recentLimit: 200) {
            recent = snap.recent
        }
        onThisDay = await client.onThisDay()
        timeMachine = await client.tasteTimeMachine()
        loaded = true
    }

    private func play(kind: String, title: String, artist: String?, album: String?, key: String) {
        guard client.hasActiveOutput, busy == nil else { return }
        Haptics.tap()
        busy = key
        Task {
            // resolveBookmark only reads kind/title/artist/album — reuse it verbatim.
            let entry = DatabaseManager.BookmarkEntry(kind: kind, key: "", title: title, artist: artist, album: album)
            let records = await client.resolveBookmark(entry)
            busy = nil
            guard !records.isEmpty else {
                client.reportError(LS("resolve.notFound"))
                return
            }
            await client.playToActiveOutput(records)
        }
    }

    private func relativeDate(_ iso: String) -> String? {
        guard let date = ISO8601DateFormatter().date(from: iso)
                ?? ISO8601DateFormatter().date(from: iso + "Z") else { return nil }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        fmt.locale = Locale(identifier: "nl_NL")
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}
