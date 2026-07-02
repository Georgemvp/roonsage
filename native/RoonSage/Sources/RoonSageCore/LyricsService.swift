import Foundation

// MARK: - Lyrics models

public struct LyricLine: Sendable, Equatable {
    public var time: Double     // seconds from track start
    public var text: String
    public init(time: Double, text: String) { self.time = time; self.text = text }
}

public struct Lyrics: Sendable, Equatable {
    public var plain: String?
    /// Timestamped lines when synced (LRC) lyrics exist — enables karaoke mode.
    public var synced: [LyricLine]?
    public var isInstrumental: Bool

    public init(plain: String? = nil, synced: [LyricLine]? = nil, isInstrumental: Bool = false) {
        self.plain = plain
        self.synced = synced
        self.isInstrumental = isInstrumental
    }

    public var hasContent: Bool {
        isInstrumental || (plain?.isEmpty == false) || (synced?.isEmpty == false)
    }
}

// MARK: - Lyrics service (LRCLIB)

/// Fetches lyrics for the now-playing track from LRCLIB — a free, no-auth,
/// community lyrics database that returns BOTH plain and synced (LRC) lyrics.
/// Kept client-side (like album art) so it needs no analyzer/server change; a
/// future increment can also read embedded lyrics tags in the analyzer for a
/// fully-offline path. Results are cached in-actor for the session.
public actor LyricsService {
    public static let shared = LyricsService()

    private let base = "https://lrclib.net/api"
    private let userAgent = "RoonSage (https://github.com/georgemvp/roonsage)"
    private var cache: [String: Lyrics?] = [:]

    public init() {}

    public func lyrics(title: String, artist: String?, album: String?, durationSec: Int?) async -> Lyrics? {
        let key = "\(artist ?? "")|\(album ?? "")|\(title)".lowercased()
        if let cached = cache[key] { return cached }
        var result = await fetchGet(title: title, artist: artist, album: album, durationSec: durationSec)
        if result == nil || result?.hasContent == false {
            result = await fetchSearch(title: title, artist: artist)
        }
        cache[key] = result
        return result
    }

    // MARK: HTTP

    /// Exact match: `/api/get` needs artist + track (+ optional album + duration;
    /// LRCLIB matches duration within a couple of seconds).
    private func fetchGet(title: String, artist: String?, album: String?, durationSec: Int?) async -> Lyrics? {
        guard let artist, !artist.isEmpty else { return nil }
        var items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let album, !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let durationSec, durationSec > 0 { items.append(URLQueryItem(name: "duration", value: "\(durationSec)")) }
        guard let obj = await getJSON(path: "/get", query: items) else { return nil }
        return Self.parse(obj)
    }

    /// Fallback fuzzy search: take the first hit that actually carries lyrics.
    private func fetchSearch(title: String, artist: String?) async -> Lyrics? {
        var items = [URLQueryItem(name: "track_name", value: title)]
        if let artist, !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        guard let arr = await getJSONArray(path: "/search", query: items) else { return nil }
        for obj in arr {
            if let lyrics = Self.parse(obj), lyrics.hasContent { return lyrics }
        }
        return nil
    }

    private func request(path: String, query: [URLQueryItem]) -> URLRequest? {
        var comp = URLComponents(string: base + path)
        comp?.queryItems = query
        guard let url = comp?.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    private func getJSON(path: String, query: [URLQueryItem]) async -> [String: Any]? {
        guard let req = request(path: path, query: query),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func getJSONArray(path: String, query: [URLQueryItem]) async -> [[String: Any]]? {
        guard let req = request(path: path, query: query),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    // MARK: Parsing (pure)

    /// Map an LRCLIB record to a `Lyrics`. Returns nil when the record carries no
    /// usable content and isn't flagged instrumental.
    static func parse(_ obj: [String: Any]) -> Lyrics? {
        let instrumental = (obj["instrumental"] as? Bool) ?? false
        let plain = (obj["plainLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let syncedRaw = obj["syncedLyrics"] as? String
        let synced = syncedRaw.map(parseLRC).flatMap { $0.isEmpty ? nil : $0 }
        let lyrics = Lyrics(plain: plain, synced: synced, isInstrumental: instrumental)
        return lyrics.hasContent ? lyrics : nil
    }

    /// Parse an LRC string into timestamped lines. Handles multiple timestamps per
    /// line (`[00:12.00][00:47.00] text`), `mm:ss.xx` and `mm:ss` forms, and skips
    /// ID-tag lines (`[ar:...]`, `[ti:...]`). Blank lyric lines are kept as pauses.
    static func parseLRC(_ raw: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var s = Substring(line)
            var stamps: [Double] = []
            while s.first == "[" {
                guard let close = s.firstIndex(of: "]") else { break }
                let tag = s[s.index(after: s.startIndex)..<close]
                if let secs = parseStamp(String(tag)) { stamps.append(secs) }
                else if !stamps.isEmpty { break }   // stop at a non-time tag once we've seen times
                s = s[s.index(after: close)...]
                if stamps.isEmpty && !tag.contains(":") { /* skip ID tag, keep scanning */ }
            }
            guard !stamps.isEmpty else { continue }
            let text = s.trimmingCharacters(in: .whitespaces)
            for t in stamps { out.append(LyricLine(time: t, text: text)) }
        }
        return out.sorted { $0.time < $1.time }
    }

    /// Parse a `mm:ss`, `mm:ss.xx` or `mm:ss.xxx` timestamp to seconds; nil for
    /// non-time tags (ID metadata).
    static func parseStamp(_ tag: String) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]) else { return nil }
        guard let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }
}
