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

    /// The 30-second MP3 preview URL of `artist`'s most popular track on Deezer —
    /// a sonic probe for an artist we don't own (so we can CLAP-embed it and score
    /// it against the taste centroid). Name-confirmed like `relatedArtists` (the
    /// hit's primary artist must normalise-equal the want), so a common prefix
    /// can't hand back an unrelated star's track. Highest Deezer `rank` (popularity)
    /// among confirmed hits wins. nil on any lookup failure or no confirmed hit.
    public func topTrackPreview(forArtist artist: String) async -> URL? {
        let want = TrackIdentity.normalise(TrackIdentity.primaryArtist(artist))
        guard !want.isEmpty else { return nil }
        guard let searchURL = url("/search/track", query: ["q": "artist:\"\(artist)\"", "limit": "10"]),
              let json = await getJSON(searchURL),
              let data = json["data"] as? [[String: Any]], !data.isEmpty else { return nil }

        var best: (rank: Int, url: URL)?
        for item in data {
            let got = TrackIdentity.normalise(
                TrackIdentity.primaryArtist((item["artist"] as? [String: Any])?["name"] as? String))
            guard got == want,
                  let preview = item["preview"] as? String, !preview.isEmpty,
                  let previewURL = URL(string: preview) else { continue }
            let rank = item["rank"] as? Int ?? 0
            if best == nil || rank > best!.rank { best = (rank, previewURL) }
        }
        return best?.url
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
        Set((await relatedArtistWeights(for: artist)).keys)
    }

    /// Rank-WEIGHTED fan-graph for a seed artist: the Deezer list is affinity-
    /// ordered, so a leading artist (Clapton for Knopfler) should pull harder than
    /// #20. Weight = 1.0 at the top decaying to ~0.4 at the tail. Adds a bounded
    /// TRANSITIVE hop (related-of-related) at half weight — cache-only, so it never
    /// fires extra Deezer calls in the build hot path; it just broadens reach for
    /// artists whose neighbours were already fetched. Keys lowercased.
    func relatedArtistWeights(for artist: String) async -> [String: Double] {
        guard !isRemote, let db = database, !artist.isEmpty else { return [:] }

        // First hop (fetch-on-miss). `try?` flattens the double optional: a DB
        // error reads as a cache miss and refetches.
        let firstHop: [String]
        if let cached = try? await db.relatedArtists(for: artist) {
            firstHop = cached
        } else if let fetched = await RelatedArtistsClient.shared.relatedArtists(for: artist) {
            try? await db.upsertRelatedArtists(artistKey: artist, related: fetched)
            if !fetched.isEmpty {
                Log.info("Verwante artiesten (Deezer) voor '\(artist)': \(fetched.count) gecachet", category: .network)
            }
            firstHop = fetched.map { $0.lowercased() }
        } else {
            return [:]   // network trouble: don't negative-cache, retry next build
        }
        guard !firstHop.isEmpty else { return [:] }

        func rankWeight(_ i: Int, _ n: Int) -> Double {
            guard n > 1 else { return 1 }
            return 1 - 0.6 * Double(i) / Double(n - 1)
        }
        var weights: [String: Double] = [:]
        for (i, name) in firstHop.enumerated() { weights[name] = rankWeight(i, firstHop.count) }

        // Transitive hop at half weight, cache-only (no fetch). Keep the strongest
        // path to any artist (max, not sum) so a hub can't dominate the pool.
        for (i, hop) in firstHop.prefix(8).enumerated() {
            guard let second = try? await db.relatedArtists(for: hop) else { continue }
            let hopW = rankWeight(i, firstHop.count) * 0.5
            for (j, name) in second.enumerated() where name != artist.lowercased() {
                let w = hopW * rankWeight(j, second.count)
                if w > (weights[name] ?? 0) { weights[name] = w }
            }
        }
        return weights
    }

    /// The rank-weighted fan-graph for a running station: the seed artist for
    /// artist radios, the seed *track's* artist for song radios (its display name
    /// is the track title), none for the bucket categories (no single seed artist).
    func relatedSeedArtists(radioID: String, artist: String) async -> [String: Double] {
        if radioID.hasPrefix("artist:") { return await relatedArtistWeights(for: artist) }
        guard radioID.hasPrefix("track:") else { return [:] }
        let mk = String(radioID.dropFirst("track:".count))
        let lib = await radioLibrary()
        guard let seed = lib.first(where: { $0.matchKey == mk || $0.id == mk }),
              let a = seed.artist, !a.isEmpty else { return [:] }
        return await relatedArtistWeights(for: a)
    }
}
