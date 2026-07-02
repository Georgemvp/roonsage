import SwiftUI
import RoonSageCore

/// Lyrics for the now-playing track. When synced (LRC) lyrics are available it
/// runs in karaoke mode: the active line is highlighted and auto-scrolled, and
/// tapping a line seeks there. Falls back to plain scrolling text, an
/// instrumental note, or a "not found" state.
@MainActor
struct LyricsView: View {
    @Environment(RoonClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let zone: Zone

    @State private var lyrics: Lyrics?
    @State private var loading = true
    // Interpolated playback position for karaoke highlighting, anchored to the
    // zone's reported seek and advanced by a light timer (same approach as the
    // Now Playing hero, so the highlight tracks the real clock).
    @State private var anchorPos: Double = 0
    @State private var anchorDate: Date = .init()
    @State private var position: Double = 0

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(zone.nowPlaying?.title ?? "Songtekst")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Klaar") { dismiss() }
                    }
                }
        }
        .task(id: zone.nowPlaying?.title) { await load() }
        .onAppear { setAnchor(zone.seekPosition ?? 0) }
        .onChange(of: zone.seekPosition) { _, p in setAnchor(p ?? 0) }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in tick() }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("Songtekst laden…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let l = lyrics, l.isInstrumental {
            ContentUnavailableView("Instrumentaal", systemImage: "music.note",
                description: Text("Deze track heeft geen songtekst."))
        } else if let synced = lyrics?.synced, !synced.isEmpty {
            karaoke(synced)
        } else if let plain = lyrics?.plain, !plain.isEmpty {
            ScrollView {
                Text(plain)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.xl)
                    .textSelection(.enabled)
            }
        } else {
            ContentUnavailableView("Geen songtekst gevonden", systemImage: "text.quote",
                description: Text("Voor deze track is geen tekst beschikbaar op LRCLIB."))
        }
    }

    // MARK: Karaoke

    private func karaoke(_ lines: [LyricLine]) -> some View {
        let active = activeIndex(lines)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(idx == active ? .title2.bold() : .title3)
                            .foregroundStyle(idx == active ? Color.roonGold : (idx < active ? .secondary : .primary))
                            .opacity(idx == active ? 1 : (abs(idx - active) <= 2 ? 0.8 : 0.45))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .id(idx)
                            .onTapGesture {
                                Haptics.tap()
                                setAnchor(line.time)
                                Task { await client.seek(zoneID: zone.id, seconds: line.time) }
                            }
                    }
                }
                .padding(Spacing.xl)
                .padding(.vertical, 120)   // let the active line settle mid-screen
            }
            .onChange(of: active) { _, new in
                guard new >= 0 else { return }
                withAnimation(Motion.standard) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    /// Index of the last line whose timestamp has passed, or -1 before the first.
    private func activeIndex(_ lines: [LyricLine]) -> Int {
        var idx = -1
        for (i, line) in lines.enumerated() {
            if line.time <= position + 0.15 { idx = i } else { break }
        }
        return idx
    }

    // MARK: Position + loading

    private func setAnchor(_ p: Double) {
        anchorPos = max(0, p)
        anchorDate = Date()
        position = anchorPos
    }

    private func tick() {
        guard zone.state == .playing else { return }
        position = anchorPos + Date().timeIntervalSince(anchorDate)
    }

    private func load() async {
        guard let np = zone.nowPlaying else { loading = false; return }
        loading = true
        // Ask the server-of-record: it serves the cached DB row or fetches from
        // LRCLIB on demand and stores it (thin clients never hit LRCLIB directly).
        lyrics = await client.lyrics(
            title: np.title, artist: np.artist, album: np.album, durationSec: np.length)
        loading = false
    }
}
