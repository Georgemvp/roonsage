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
