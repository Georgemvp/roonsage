import AudioAnalysis
import Foundation

/// Deezer web-service client used by the analyzer to attach a global *popularity*
/// signal to each track — Deezer exposes a `rank` per track (its internal
/// popularity score, higher = more played worldwide), which the smart radios use
/// to steer the adventurousness dial toward hits or deep cuts.
///
/// Runs ONLY in the analyzer/server process — never on a thin client — so the
/// rate-limited lookups stay off the apps. The result flows to the apps through
/// the analyzer's `/features` HTTP export, exactly like audio features and
/// MusicBrainz genres.
///
/// Deezer's public API needs NO authentication (unlike Last.fm's per-app key or
/// Spotify's OAuth) — only a courteous request rate. The documented ceiling is
/// ~50 requests / 5 s; the actor serialises every request through a reservation
/// gate at `minInterval` spacing, mirroring `MusicBrainzClient`.
public actor DeezerClient {
    public static let shared = DeezerClient()

    private let base = "https://api.deezer.com"
    /// Minimum spacing between requests. 0.15s ≈ 6.6 req/s, well under Deezer's
    /// ~10 req/s ceiling with headroom for jitter.
    private let minInterval: TimeInterval
    /// The next instant a request is allowed to fire. Reserved BEFORE the await
    /// so overlapping callers serialise instead of all reading the same slot.
    private var nextSlot: Date = .distantPast

    public init(minInterval: TimeInterval = 0.15) {
        self.minInterval = max(0, minInterval)
    }

    // MARK: - Popularity

    /// The Deezer `rank` (global popularity, ~0…1_000_000) for a track, or nil
    /// when nothing confidently matches. Searches artist+title, then only trusts
    /// a candidate whose primary artist agrees with the wanted one — so a common
    /// title ("Home", "Alive") doesn't inherit an unrelated blockbuster's rank.
    /// Best-effort: any network/parse failure returns nil (caller stamps it as
    /// "checked, not found" so it isn't retried forever).
    public func popularity(artist: String, title: String) async -> Int? {
        let a = artist.trimmingCharacters(in: .whitespaces)
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !t.isEmpty else { return nil }

        // Advanced query syntax: artist:"…" track:"…" — quoted for exact-ish match.
        let q = "artist:\"\(escape(a))\" track:\"\(escape(t))\""
        guard let url = url("/search", query: ["q": q, "limit": "5"]),
              let json = await getJSON(url),
              let data = json["data"] as? [[String: Any]], !data.isEmpty else { return nil }

        let wantArtist = TrackIdentity.normalise(TrackIdentity.primaryArtist(a))
        guard !wantArtist.isEmpty else { return nil }

        for item in data {
            let gotArtist = TrackIdentity.normalise(
                TrackIdentity.primaryArtist((item["artist"] as? [String: Any])?["name"] as? String))
            guard artistMatches(want: wantArtist, got: gotArtist) else { continue }
            if let rank = item["rank"] as? Int { return rank }
            if let rank = (item["rank"] as? NSNumber)?.intValue { return rank }
        }
        return nil
    }

    /// Lenient primary-artist agreement: equal, or one contained in the other
    /// (covers "bonobo" vs "bonobo simz" edge cases without matching noise).
    private func artistMatches(want: String, got: String) -> Bool {
        guard !got.isEmpty else { return false }
        return want == got || want.contains(got) || got.contains(want)
    }

    // MARK: - Genre (album-detail lookup, for owned-track genre backfill)

    /// The Deezer album id for a matched track — same search + artist-match logic
    /// as `popularity`, but returns the album id instead of the rank so a caller
    /// (`DeezerGenreEnricher`) can follow up with an album-detail lookup. A
    /// second signal alongside MusicBrainz genres, whose per-release coverage is
    /// sparse — Deezer's `AlbumGenreName` fills gaps MB never resolves.
    public func trackAlbumID(artist: String, title: String) async -> Int? {
        let a = artist.trimmingCharacters(in: .whitespaces)
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !t.isEmpty else { return nil }

        let q = "artist:\"\(escape(a))\" track:\"\(escape(t))\""
        guard let url = url("/search", query: ["q": q, "limit": "5"]),
              let json = await getJSON(url),
              let data = json["data"] as? [[String: Any]], !data.isEmpty else { return nil }

        let wantArtist = TrackIdentity.normalise(TrackIdentity.primaryArtist(a))
        guard !wantArtist.isEmpty else { return nil }

        for item in data {
            let gotArtist = TrackIdentity.normalise(
                TrackIdentity.primaryArtist((item["artist"] as? [String: Any])?["name"] as? String))
            guard artistMatches(want: wantArtist, got: gotArtist) else { continue }
            if let albumID = (item["album"] as? [String: Any])?["id"] as? Int { return albumID }
        }
        return nil
    }

    /// Genres for a Deezer album (`/album/{id}`), or nil on any lookup/parse
    /// failure or an album Deezer has no genre data for.
    public func albumGenres(albumID: Int) async -> [String]? {
        guard let url = url("/album/\(albumID)", query: [:]),
              let json = await getJSON(url) else { return nil }
        return Self.parseGenres(fromAlbumJSON: json)
    }

    /// Pure parse of `/album/{id}`'s `genres.data[].name` — separated so it's
    /// unit-testable against a fixture payload. Drops Deezer's generic "All"
    /// bucket (an unclassified placeholder, not a real genre).
    public static func parseGenres(fromAlbumJSON json: [String: Any]) -> [String]? {
        guard let genresObj = json["genres"] as? [String: Any],
              let data = genresObj["data"] as? [[String: Any]] else { return nil }
        let names = data.compactMap { $0["name"] as? String }.filter { !$0.isEmpty && $0 != "All" }
        return names.isEmpty ? nil : names
    }

    // MARK: - Preview resolution (embedding backfill for file-less tracks)

    /// One confidently-matched Deezer track with a streamable 30s MP3 preview.
    public struct PreviewHit: Sendable {
        public let id: Int
        public let previewURL: URL
        public let durationSec: Int
    }

    /// Resolve a (artist, title) want to a Deezer preview — STRICTER than the
    /// popularity lookup, because a wrong match here poisons an embedding, not
    /// just a rank: the artist must match exactly (normalised primary artist,
    /// no substring leniency) AND the cleaned title must match exactly. Nil on
    /// no confident match or any network trouble.
    public func preview(artist: String, title: String) async -> PreviewHit? {
        let a = artist.trimmingCharacters(in: .whitespaces)
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !t.isEmpty else { return nil }

        let q = "artist:\"\(escape(a))\" track:\"\(escape(t))\""
        guard let url = url("/search", query: ["q": q, "limit": "5"]),
              let json = await getJSON(url),
              let data = json["data"] as? [[String: Any]], !data.isEmpty else { return nil }

        let wantArtist = TrackIdentity.normalise(TrackIdentity.primaryArtist(a))
        let wantTitle = TrackIdentity.normalise(TrackIdentity.cleanTitle(t))
        guard !wantArtist.isEmpty, !wantTitle.isEmpty else { return nil }

        for item in data {
            let gotArtist = TrackIdentity.normalise(
                TrackIdentity.primaryArtist((item["artist"] as? [String: Any])?["name"] as? String))
            let gotTitle = TrackIdentity.normalise(
                TrackIdentity.cleanTitle(item["title"] as? String ?? ""))
            guard gotArtist == wantArtist, gotTitle == wantTitle,
                  let id = item["id"] as? Int,
                  let preview = item["preview"] as? String, !preview.isEmpty,
                  let previewURL = URL(string: preview) else { continue }
            return PreviewHit(id: id, previewURL: previewURL,
                              durationSec: item["duration"] as? Int ?? 0)
        }
        return nil
    }

    // MARK: - HTTP

    /// Reserve the next rate-limit slot, sleep until it, then fetch + decode JSON.
    /// nil on any non-200 / decode failure / Deezer `error` payload — popularity
    /// is best-effort and never throws.
    private func getJSON(_ url: URL) async -> [String: Any]? {
        await awaitSlot()
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if json["error"] != nil { return nil }   // Deezer returns {"error": {...}} on quota / bad query
        return json
    }

    /// Block until this caller's reserved slot. Reserving `nextSlot` before the
    /// suspension point is what serialises concurrent callers (actor reentrancy
    /// would otherwise let them all read the same past instant).
    private func awaitSlot() async {
        let now = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(minInterval)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    private func url(_ path: String, query: [String: String]) -> URL? {
        var comp = URLComponents(string: base + path)
        comp?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comp?.url
    }

    /// Escape the double-quotes Deezer's advanced query uses as phrase delimiters.
    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: " ")
    }
}
