import RoonSageCore
import SwiftUI

// MARK: - Bookmark toggle button (mirrors FavoriteStarButton)

/// Bordered bookmark toggle used next to the favorite star on albums/artists
/// and in the track play-actions menu.
@MainActor
struct BookmarkButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: isOn ? "bookmark.fill" : "bookmark")
                .foregroundStyle(isOn ? Color.roonGold : .secondary)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(isOn ? "Verwijder uit bewaard" : "Bewaar voor later")
        .help(isOn ? "Verwijder uit bewaard" : "Bewaar voor later")
    }
}

// MARK: - Bewaard voor later (bookmarks list)

/// The "Bewaar voor later" list: everything the user bookmarked across tracks,
/// albums and artists, newest first, grouped by kind. Tapping a row plays it on
/// the active output (resolved live against the current library).
@MainActor
struct BookmarksView: View {
    @Environment(RoonClient.self) private var client
    @State private var loaded = false
    @State private var busyKey: String?

    private struct Group: Identifiable {
        let kind: String
        let title: String
        let icon: String
        let items: [DatabaseManager.BookmarkEntry]
        var id: String { kind }
    }

    private var groups: [Group] {
        let order: [(String, String, String)] = [
            ("track", LS("bm.section.tracks"), "music.note"),
            ("album", LS("bm.section.albums"), "square.stack"),
            ("artist", LS("bm.section.artists"), "person.2"),
        ]
        return order.compactMap { kind, title, icon in
            let items = client.bookmarks.filter { $0.kind == kind }
            return items.isEmpty ? nil : Group(kind: kind, title: title, icon: icon, items: items)
        }
    }

    var body: some View {
        AsyncStateView(isLoading: !loaded, isEmpty: client.bookmarks.isEmpty) {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.items, id: \.key) { entry in
                            row(entry)
                        }
                    } header: {
                        Label(group.title, systemImage: group.icon)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
        } empty: {
            ContentUnavailableView {
                Label { LT("bm.empty.title") } icon: { Image(systemName: "bookmark") }
            } description: {
                LT("bm.empty.desc")
            }
        }
        .navigationTitle(LS("nav.bookmarks"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task {
            await client.ensureBookmarksLoaded()
            loaded = true
        }
    }

    private func row(_ entry: DatabaseManager.BookmarkEntry) -> some View {
        Button {
            play(entry)
        } label: {
            HStack(spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title ?? "—").font(.body).lineLimit(1)
                    if let sub = subtitle(entry) {
                        Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if busyKey == entry.key {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.circle")
                        .foregroundStyle(client.hasActiveOutput ? Color.roonGold : .secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!client.hasActiveOutput)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                remove(entry)
            } label: { Label { LT("action.delete") } icon: { Image(systemName: "trash") } }
        }
        .contextMenu {
            Button { play(entry) } label: { Label { LT("bm.playNow") } icon: { Image(systemName: "play.fill") } }
                .disabled(!client.hasActiveOutput)
            Button(role: .destructive) { remove(entry) } label: {
                Label { LT("bm.remove") } icon: { Image(systemName: "bookmark.slash") }
            }
        }
    }

    private func subtitle(_ e: DatabaseManager.BookmarkEntry) -> String? {
        switch e.kind {
        case "track":
            return [e.artist, e.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case "album":
            return e.artist
        default:
            return nil
        }
    }

    private func play(_ entry: DatabaseManager.BookmarkEntry) {
        guard client.hasActiveOutput, busyKey == nil else { return }
        Haptics.tap()
        busyKey = entry.key
        Task {
            let records = await client.resolveBookmark(entry)
            busyKey = nil
            guard !records.isEmpty else {
                client.reportError(LS("resolve.notFound"))
                return
            }
            await client.playToActiveOutput(records)
        }
    }

    private func remove(_ entry: DatabaseManager.BookmarkEntry) {
        Task {
            switch entry.kind {
            case "track":  await client.toggleBookmarkTrack(title: entry.title ?? "", artist: entry.artist, album: entry.album)
            case "album":  await client.toggleBookmarkAlbum(album: entry.title ?? "", artist: entry.artist)
            case "artist": await client.toggleBookmarkArtist(entry.title ?? "")
            default: break
            }
        }
    }
}
