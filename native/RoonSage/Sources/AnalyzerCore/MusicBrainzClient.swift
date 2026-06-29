import Foundation

/// MusicBrainz web-service client used by the analyzer to enrich tracks with a
/// rich, hierarchical genre vocabulary (far beyond Roon's ~20 top-level genres).
///
/// Runs ONLY in the analyzer/server process — never on a thin client — so the
/// rate-limited, long-running lookups stay off the apps. Results flow to the
/// apps through the analyzer's `/features` + `/genres` HTTP endpoints, exactly
/// like audio features.
///
/// Two hard MusicBrainz rules are baked in:
///   • a descriptive `User-Agent` is REQUIRED — generic agents get HTTP 403,
///   • anonymous callers get ~1 request/second — exceeding it returns 503.
/// The actor serialises every request through a reservation gate so concurrent
/// callers queue at ≥`minInterval` spacing instead of hammering the service.
public actor MusicBrainzClient {
    public static let shared = MusicBrainzClient()

    private let base = "https://musicbrainz.org/ws/2"
    private let userAgent: String
    /// Minimum spacing between requests. 1.1s leaves headroom under MB's 1 req/s.
    private let minInterval: TimeInterval
    /// The next instant a request is allowed to fire. Reserved BEFORE the await
    /// so overlapping callers serialise instead of all reading the same slot.
    private var nextSlot: Date = .distantPast

    public init(userAgent: String = "RoonSage/2.0 ( https://github.com/georgemvp/roonsage )",
                minInterval: TimeInterval = 1.1) {
        self.userAgent = userAgent
        self.minInterval = max(0, minInterval)
    }

    // MARK: - Genres for an album / track

    /// Controlled-vocabulary genres for an album, most-voted first. Resolves the
    /// best release candidate by search, then reads genres off its release-group
    /// (cleaner/more stable than a specific pressing), falling back to the
    /// release and then its free-text tags. Empty when nothing matches.
    public func genresForAlbum(artist: String, album: String, minVotes: Int = 1, limit: Int = 6) async -> [String] {
        let a = artist.trimmingCharacters(in: .whitespaces)
        let al = album.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !al.isEmpty else { return [] }
        let query = "release:\(lucene(al)) AND artist:\(lucene(a))"
        guard let url = url("/release", query: ["query": query, "limit": "3"]),
              let json = await getJSON(url),
              let releases = json["releases"] as? [[String: Any]], !releases.isEmpty else { return [] }
        let best = releases[0]
        if let rg = best["release-group"] as? [String: Any], let rgID = rg["id"] as? String,
           let g = await genresForEntity("release-group", id: rgID, minVotes: minVotes, limit: limit), !g.isEmpty {
            return g
        }
        if let relID = best["id"] as? String,
           let g = await genresForEntity("release", id: relID, minVotes: minVotes, limit: limit), !g.isEmpty {
            return g
        }
        return []
    }

    /// Controlled-vocabulary genres for a single recording (artist + title) —
    /// the fallback used when an album lookup misses (compilations, singles).
    public func genresForTrack(artist: String, title: String, minVotes: Int = 1, limit: Int = 6) async -> [String] {
        let a = artist.trimmingCharacters(in: .whitespaces)
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !t.isEmpty else { return [] }
        let query = "recording:\(lucene(t)) AND artist:\(lucene(a))"
        guard let url = url("/recording", query: ["query": query, "limit": "3"]),
              let json = await getJSON(url),
              let recs = json["recordings"] as? [[String: Any]], let first = recs.first,
              let recID = first["id"] as? String else { return [] }
        return await genresForEntity("recording", id: recID, minVotes: minVotes, limit: limit) ?? []
    }

    /// Genres on a specific MB entity (`release-group` / `release` / `recording`),
    /// sorted by descending vote count and thresholded at `minVotes`. Falls back
    /// to the entity's free-text `tags` when it carries no controlled genres.
    private func genresForEntity(_ type: String, id: String, minVotes: Int, limit: Int) async -> [String]? {
        guard let url = url("/\(type)/\(id)", query: ["inc": "genres+tags"]),
              let json = await getJSON(url) else { return nil }
        if let genres = json["genres"] as? [[String: Any]], !genres.isEmpty {
            let names = sortedNames(genres, minVotes: minVotes, limit: limit)
            if !names.isEmpty { return names }
        }
        if let tags = json["tags"] as? [[String: Any]] {
            return sortedNames(tags, minVotes: max(minVotes, 1), limit: limit)
        }
        return []
    }

    // MARK: - Genre taxonomy (hierarchy)

    public struct GenreNode: Sendable {
        public let name: String
        public let mbid: String
    }

    /// Outcome of a full-vocabulary fetch. `complete` is true only when pagination
    /// reached MusicBrainz's advertised end with at least one genre in hand; a
    /// transient failure mid-pagination (or an empty/parse-failed first page)
    /// returns the pages gathered so far with `complete == false`, so the caller
    /// knows NOT to treat the partial set as the whole vocabulary.
    public struct GenreVocabulary: Sendable {
        public let nodes: [GenreNode]
        public let complete: Bool
    }

    /// The full MusicBrainz genre vocabulary (~2000 entries), name + MBID. One
    /// pass, paginated. Forms the flat backbone of the taxonomy before parent
    /// relations are resolved. Any failed/malformed page aborts with
    /// `complete == false`: a partial result must not masquerade as the complete
    /// vocabulary, or genres on the not-yet-fetched pages get stamped as false
    /// roots and the hierarchy stays permanently broken.
    public func allGenres(pageSize: Int = 100) async -> GenreVocabulary {
        var out: [GenreNode] = []
        var offset = 0
        while true {
            guard let url = url("/genre/all", query: ["limit": "\(pageSize)", "offset": "\(offset)"]),
                  let json = await getJSON(url),
                  let arr = json["genres"] as? [[String: Any]] else {
                return GenreVocabulary(nodes: out, complete: false)   // fetch/parse failed mid-way
            }
            for g in arr {
                if let name = (g["name"] as? String)?.lowercased(), let id = g["id"] as? String {
                    out.append(GenreNode(name: name, mbid: id))
                }
            }
            let total = json["genre-count"] as? Int ?? 0
            offset += arr.count
            // Reached the end cleanly: an empty/short page, or the advertised total.
            // Treat a totally empty result as INCOMPLETE (MB always has ~2000 genres,
            // so empty means something failed) — it'll be retried on the next run.
            if arr.isEmpty || arr.count < pageSize || (total > 0 && offset >= total) {
                return GenreVocabulary(nodes: out, complete: !out.isEmpty)
            }
        }
    }

    /// Parent genre names for a genre MBID, via its `subgenre of` relations
    /// (direction `backward` points at the parent). Returns [] when the genre is
    /// a root, and nil when the service exposes no genre relations at all — the
    /// caller treats nil as "hierarchy unavailable" and keeps a flat vocabulary.
    public func parentGenres(mbid: String) async -> [String]? {
        guard let url = url("/genre/\(mbid)", query: ["inc": "genre-rels"]),
              let json = await getJSON(url) else { return nil }
        guard let rels = json["relations"] as? [[String: Any]] else { return nil }
        var parents: [String] = []
        for rel in rels {
            guard (rel["type"] as? String) == "subgenre of" else { continue }
            // backward = this genre is a subgenre of the related one (the parent).
            if (rel["direction"] as? String) == "backward",
               let g = rel["genre"] as? [String: Any], let name = (g["name"] as? String)?.lowercased() {
                parents.append(name)
            }
        }
        return parents
    }

    // MARK: - HTTP

    /// Reserve the next rate-limit slot, sleep until it, then fetch + decode JSON.
    /// Retries once on 503 (rate limited). nil on any non-200 / decode failure —
    /// enrichment is best-effort and never throws.
    private func getJSON(_ url: URL) async -> [String: Any]? {
        for attempt in 0..<2 {
            await awaitSlot()
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            if code == 503, attempt == 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)   // back off, then retry once
                continue
            }
            return nil
        }
        return nil
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
        var items = [URLQueryItem(name: "fmt", value: "json")]
        items.append(contentsOf: query.map { URLQueryItem(name: $0.key, value: $0.value) })
        comp?.queryItems = items
        return comp?.url
    }

    /// Escape Lucene metacharacters and wrap a phrase in quotes for an exact-ish
    /// field match in the MB search query DSL.
    private func lucene(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "+-&|!(){}[]^\"~*?:\\/".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return "\"\(out)\""
    }

    /// Pull `name` strings from a MB genres/tags array, dropping entries below
    /// `minVotes`, sorted by descending `count`, capped at `limit`, deduped.
    private func sortedNames(_ arr: [[String: Any]], minVotes: Int, limit: Int) -> [String] {
        let scored = arr.compactMap { e -> (String, Int)? in
            guard let name = (e["name"] as? String)?.lowercased(), !name.isEmpty else { return nil }
            let votes = e["count"] as? Int ?? 0
            return votes >= minVotes ? (name, votes) : nil
        }.sorted { $0.1 > $1.1 }
        var seen = Set<String>()
        var out: [String] = []
        for (name, _) in scored where seen.insert(name).inserted {
            out.append(name)
            if out.count >= limit { break }
        }
        return out
    }
}
