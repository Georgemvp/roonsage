import AudioAnalysis
import Foundation

/// Deezer "fans also like" — the global *collaborative* signal the content-based
/// radios lacked: CLAP hears that two tracks sound alike, this knows that people
/// who play the seed artist also play these others. Keyless public API (like the
/// popularity enricher), two requests per seed artist, cached ~30 days in
/// `related_artists`, fetched only on the server-of-record.
public actor RelatedArtistsClient {
    public static let shared = RelatedArtistsClient()

    private let base = "https://api.deezer.com"
    /// Modest spacing — a handful of lookups per radio build, nowhere near
    /// Deezer's ceiling, but stay courteous anyway.
    private let minInterval: TimeInterval = 0.25
    private var nextSlot: Date = .distantPast

    public init() {}

    /// The related artist names for `artist` (Deezer's order = affinity order),
    /// or nil on any lookup failure (so the caller can distinguish "Deezer had
    /// nothing" — an empty array — from "couldn't ask", and only negative-cache
    /// the former).
    public func relatedArtists(for artist: String, limit: Int = 25) async -> [String]? {
        let want = artist.trimmingCharacters(in: .whitespaces)
        guard !want.isEmpty else { return [] }

        // 1. Resolve the artist id — accept only a name-confirmed hit, so a
        //    common prefix can't inherit an unrelated star's fan graph.
        guard let searchURL = url("/search/artist", query: ["q": want, "limit": "5"]),
              let search = await getJSON(searchURL),
              let hits = search["data"] as? [[String: Any]] else { return nil }
        let wantForm = TrackIdentity.normalise(TrackIdentity.primaryArtist(want))
        guard !wantForm.isEmpty else { return [] }
        var artistID: Int?
        for h in hits {
            let name = TrackIdentity.normalise(TrackIdentity.primaryArtist(h["name"] as? String))
            if name == wantForm { artistID = h["id"] as? Int; break }
        }
        guard let id = artistID else { return [] }   // genuinely unknown → negative-cacheable

        // 2. The fan graph.
        guard let relURL = url("/artist/\(id)/related", query: ["limit": String(limit)]),
              let rel = await getJSON(relURL),
              let data = rel["data"] as? [[String: Any]] else { return nil }
        return data.compactMap { $0["name"] as? String }
    }

    // MARK: HTTP (mirrors DeezerClient's reservation gate)

    private func getJSON(_ url: URL) async -> [String: Any]? {
        await awaitSlot()
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if json["error"] != nil { return nil }
        return json
    }

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
}

extension RoonClient {

    /// The lowercased related-artist set for one seed artist — DB-cache first,
    /// a live Deezer fetch (persisted) on miss/staleness. Only the always-on
    /// server fetches; a thin client returns [] (its radios come pre-built from
    /// the server anyway). Failures return [] without poisoning the cache.
    func relatedArtistKeys(for artist: String) async -> Set<String> {
        guard !isRemote, let db = database, !artist.isEmpty else { return [] }
        // `try?` flattens the double optional: a DB error reads as a cache miss
        // and simply refetches.
        if let cached = try? await db.relatedArtists(for: artist) {
            return Set(cached)
        }
        guard let fetched = await RelatedArtistsClient.shared.relatedArtists(for: artist) else {
            return []   // network trouble: don't negative-cache, retry next build
        }
        try? await db.upsertRelatedArtists(artistKey: artist, related: fetched)
        if !fetched.isEmpty {
            Log.info("Verwante artiesten (Deezer) voor '\(artist)': \(fetched.count) gecachet", category: .network)
        }
        return Set(fetched.map { $0.lowercased() })
    }

    /// The fan-graph seed set for a running station: the seed artist for artist
    /// radios, the seed *track's* artist for song radios (its display name is
    /// the track title), none for the bucket categories (no single seed artist).
    func relatedSeedArtists(radioID: String, artist: String) async -> Set<String> {
        if radioID.hasPrefix("artist:") { return await relatedArtistKeys(for: artist) }
        guard radioID.hasPrefix("track:") else { return [] }
        let mk = String(radioID.dropFirst("track:".count))
        let lib = await radioLibrary()
        guard let seed = lib.first(where: { $0.matchKey == mk || $0.id == mk }),
              let a = seed.artist, !a.isEmpty else { return [] }
        return await relatedArtistKeys(for: a)
    }
}
