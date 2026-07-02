import AudioAnalysis
import Foundation

@MainActor
extension RoonClient {

    // MARK: - Client-facing (remote-aware)

    /// Lyrics for a track. Thin clients ask the server (which caches into its DB and
    /// fetches from LRCLIB on a miss); the server build resolves locally. Returns nil
    /// when no lyrics exist.
    public func lyrics(title: String, artist: String?, album: String?, durationSec: Int?) async -> Lyrics? {
        if isRemote {
            guard let base = remoteBaseURL else { return nil }
            var comp = URLComponents(string: "\(base)/lyrics")
            var items = [URLQueryItem(name: "title", value: title)]
            if let artist { items.append(URLQueryItem(name: "artist", value: artist)) }
            if let album { items.append(URLQueryItem(name: "album", value: album)) }
            if let durationSec { items.append(URLQueryItem(name: "duration", value: "\(durationSec)")) }
            comp?.queryItems = items
            guard let url = comp?.url else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 14)
            authorizeShareRequest(&req)
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode(Lyrics.self, from: data)
        }
        return await resolveLyrics(title: title, artist: artist, album: album, durationSec: durationSec)
    }

    // MARK: - Server-side coordinator (check DB → fetch → store)

    /// Resolve lyrics on the server-of-record: serve the cached row if present
    /// (including a cached "none"), otherwise fetch from LRCLIB, store, and return.
    func resolveLyrics(title: String, artist: String?, album: String?, durationSec: Int?) async -> Lyrics? {
        let key = TrackIdentity.matchKey(artist: artist, album: album, title: title)
        if !key.isEmpty, let db = database,
           let existing = await Task.detached(operation: { db.storedLyrics(matchKey: key) }).value {
            return existing.hasContent ? existing : nil   // row exists → don't refetch
        }
        let fetched = await LyricsService.shared.lyrics(
            title: title, artist: artist, album: album, durationSec: durationSec)
        if !key.isEmpty, let db = database {
            _ = await Task.detached(operation: { try? db.upsertLyrics(matchKey: key, lyrics: fetched, source: "lrclib") }).value
        }
        return (fetched?.hasContent ?? false) ? fetched : nil
    }

    /// `/lyrics` endpoint body: the resolved `Lyrics`, or the literal `null`.
    public func lyricsData(title: String, artist: String?, album: String?, durationSec: Int?) async -> Data {
        let l = await resolveLyrics(title: title, artist: artist, album: album, durationSec: durationSec)
        if let l, let data = try? JSONEncoder().encode(l) { return data }
        return Data("null".utf8)
    }

    // MARK: - Background backfill (server build only)

    /// Trickle lyrics for the whole library into the DB, gently (one request at a
    /// time, ~1 s apart — courteous to the free LRCLIB service). Idempotent +
    /// resumable: only tracks with no `track_lyrics` row are fetched, so it stops
    /// when coverage is complete and a relaunch continues where it left off.
    public func startLyricsBackfill() {
        guard controlMode == .direct, !lyricsBackfillStarted else { return }
        lyricsBackfillStarted = true
        Task { await runLyricsBackfill() }
    }

    private func runLyricsBackfill() async {
        guard let db = database else { return }
        Log.info("lyrics backfill: starting", category: .network)
        var filled = 0
        while !Task.isCancelled {
            let targets = await Task.detached(operation: { db.tracksMissingLyrics(limit: 40) }).value
            if targets.isEmpty { break }
            for t in targets {
                if Task.isCancelled { break }
                let fetched = await LyricsService.shared.lyrics(
                    title: t.title, artist: t.artist, album: t.album, durationSec: t.durationSec)
                _ = await Task.detached(operation: {
                    try? db.upsertLyrics(matchKey: t.matchKey, lyrics: fetched, source: "lrclib")
                }).value
                if fetched?.hasContent == true { filled += 1 }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        let counts = await Task.detached(operation: { db.lyricsCounts() }).value
        Log.info("lyrics backfill: done — \(counts.withLyrics)/\(counts.total) tracks have lyrics (+\(filled) this run)",
                 category: .network)
    }
}
