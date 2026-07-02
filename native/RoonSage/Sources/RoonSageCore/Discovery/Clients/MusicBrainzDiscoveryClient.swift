import AudioAnalysis
import Foundation

// MARK: - MusicBrainz client for the discovery pipeline
//
// A focused, RoonSageCore-local MusicBrainz client for the Resolve stage and the
// release-radar / gap-fill / artist-relationship producers. It is SEPARATE from
// `AnalyzerCore/MusicBrainzClient` (which is genre-taxonomy only and lives in a
// module RoonSageCore can't import) — but reuses its exact rate-limit reservation
// pattern (≥1.1s spacing, descriptive User-Agent, retry-once on 503). Runs only
// on the always-on server build. Results are cached in-actor so a daily batch's
// repeated artist lookups don't re-hit the service.
public actor MusicBrainzDiscoveryClient {
    public static let shared = MusicBrainzDiscoveryClient()

    private let base = "https://musicbrainz.org/ws/2"
    private let userAgent: String
    private let minInterval: TimeInterval
    private var nextSlot: Date = .distantPast

    // Per-run caches (artist MBID by normalized name; studio RGs by artist MBID;
    // Cover Art Archive front image by release-group MBID).
    private var artistCache: [String: MBArtistMatch?] = [:]
    private var studioCache: [String: [MBReleaseGroup]] = [:]
    private var coverCache: [String: URL?] = [:]

    public init(userAgent: String = "RoonSage/2.0 ( https://github.com/georgemvp/roonsage )",
                minInterval: TimeInterval = 1.1) {
        self.userAgent = userAgent
        self.minInterval = max(0, minInterval)
    }

    /// Drop the per-run caches (called at the start of each pipeline run so a fresh
    /// run can pick up MB changes, while a single run stays cheap).
    public func resetCache() { artistCache = [:]; studioCache = [:]; coverCache = [:] }

    // MARK: - Models

    public struct MBArtistMatch: Sendable {
        public var name: String
        public var mbid: String
        public var disambiguation: String?
        /// Folksonomy tags from the search hit, lowercased and ordered by vote count
        /// (most-agreed first). A mix of genres ("rock", "blues rock") and noise
        /// ("british", "1980s", "seen live") — the pipeline filters these against the
        /// MB genre taxonomy so only real genres reach scoring/display.
        public var tags: [String] = []
    }

    public struct MBReleaseGroup: Sendable {
        public var mbid: String
        public var title: String
        public var primaryType: String?
        public var firstReleaseDate: String?   // "YYYY[-MM[-DD]]"
        public var year: Int? {
            guard let d = firstReleaseDate, let y = Int(d.prefix(4)) else { return nil }
            return y
        }
    }

    public struct MBRelatedArtist: Sendable {
        public var name: String
        public var mbid: String
        public var relation: String            // e.g. "member of band", "collaboration"
    }

    // MARK: - Artist resolution (validation + dedup + hallucination kill)

    /// Resolve a free-text artist name to its canonical MB name + MBID. Accepts the
    /// top hit only when its normalized name matches the query or its MB score is
    /// high — so a garbage/hallucinated name resolves to nil and is dropped by the
    /// resolver. Cached by normalized name.
    public func resolveArtist(name: String) async -> MBArtistMatch? {
        let key = TrackIdentity.normalise(name)
        guard !key.isEmpty else { return nil }
        if let cached = artistCache[key] { return cached }

        let match: MBArtistMatch?
        if let url = url("/artist", query: ["query": "artist:\(lucene(name))", "limit": "5"]),
           let json = await getJSON(url),
           let artists = json["artists"] as? [[String: Any]], !artists.isEmpty {
            let wantNorm = key
            var best: MBArtistMatch?
            for a in artists {
                guard let id = a["id"] as? String, let nm = a["name"] as? String else { continue }
                let score = a["score"] as? Int ?? 0
                let exact = TrackIdentity.normalise(nm) == wantNorm
                if exact {
                    best = MBArtistMatch(name: nm, mbid: id, disambiguation: a["disambiguation"] as? String,
                                         tags: Self.parseTags(a))
                    break
                }
                if best == nil, score >= 90 {
                    best = MBArtistMatch(name: nm, mbid: id, disambiguation: a["disambiguation"] as? String,
                                         tags: Self.parseTags(a))
                }
            }
            match = best
        } else {
            match = nil
        }
        artistCache[key] = match
        return match
    }

    /// Extract an artist search hit's `tags` array into lowercased names ordered by
    /// vote count (highest first), dropping unvoted/zero-count noise. Best-effort:
    /// an artist with no tags simply yields `[]`.
    private static func parseTags(_ artist: [String: Any]) -> [String] {
        guard let raw = artist["tags"] as? [[String: Any]] else { return [] }
        return raw
            .compactMap { t -> (name: String, count: Int)? in
                guard let name = (t["name"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces),
                      !name.isEmpty else { return nil }
                return (name, t["count"] as? Int ?? 0)
            }
            .filter { $0.count > 0 }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .map(\.name)
    }

    // MARK: - Studio release-groups (gap-fill + release-radar)

    /// An artist's studio albums, newest first: primary-type Album with NO secondary
    /// types (excludes compilations, live, soundtrack, remix, DJ-mix). Cached by MBID.
    public func studioAlbums(artistMbid: String) async -> [MBReleaseGroup] {
        guard !artistMbid.isEmpty else { return [] }
        if let cached = studioCache[artistMbid] { return cached }

        var out: [MBReleaseGroup] = []
        var offset = 0
        let pageSize = 100
        while true {
            guard let url = url("/release-group", query: [
                "artist": artistMbid, "type": "album",
                "limit": "\(pageSize)", "offset": "\(offset)",
            ]), let json = await getJSON(url),
               let arr = json["release-groups"] as? [[String: Any]] else { break }
            for rg in arr {
                guard let id = rg["id"] as? String, let title = rg["title"] as? String else { continue }
                let secondary = (rg["secondary-types"] as? [String]) ?? []
                guard secondary.isEmpty else { continue }   // studio only
                out.append(MBReleaseGroup(
                    mbid: id, title: title,
                    primaryType: rg["primary-type"] as? String,
                    firstReleaseDate: rg["first-release-date"] as? String))
            }
            let total = json["release-group-count"] as? Int ?? 0
            offset += arr.count
            if arr.isEmpty || arr.count < pageSize || (total > 0 && offset >= total) { break }
        }
        out.sort { ($0.firstReleaseDate ?? "") > ($1.firstReleaseDate ?? "") }
        studioCache[artistMbid] = out
        return out
    }

    // MARK: - Cover art (Cover Art Archive)

    /// The front cover for a release-group from the Cover Art Archive — the REAL
    /// album art, used to give gap-fill / release-radar albums a correct hero even
    /// when they don't resolve on Qobuz (avoids the misleading same-artist stand-in
    /// cover the pipeline would otherwise fall back to). Returns a 500px thumbnail
    /// URL when art exists, else nil (no art on file). Cached by MBID.
    ///
    /// CAA is a SEPARATE host from the MB webservice and is not subject to the MB
    /// 1req/1.1s rule, so this bypasses `awaitSlot` — but reuses the descriptive
    /// User-Agent CAA also asks for.
    public func coverArt(releaseGroupMbid: String) async -> URL? {
        guard !releaseGroupMbid.isEmpty else { return nil }
        if let cached = coverCache[releaseGroupMbid] { return cached }

        var result: URL?
        if let url = URL(string: "https://coverartarchive.org/release-group/\(releaseGroupMbid)") {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let images = json["images"] as? [[String: Any]], !images.isEmpty {
                // Prefer the flagged front image; fall back to the first available.
                let pick = images.first(where: { ($0["front"] as? Bool) == true }) ?? images.first
                let thumbs = pick?["thumbnails"] as? [String: Any]
                let candidate = (thumbs?["500"] as? String)
                    ?? (thumbs?["large"] as? String)
                    ?? (pick?["image"] as? String)
                if let s = candidate { result = URL(string: s) }
            }
        }
        coverCache[releaseGroupMbid] = result
        return result
    }

    // MARK: - Related artists (collaboration graph)

    /// Artists related to `artistMbid` via band-membership / collaboration relations.
    public func relatedArtists(artistMbid: String) async -> [MBRelatedArtist] {
        guard !artistMbid.isEmpty,
              let url = url("/artist/\(artistMbid)", query: ["inc": "artist-rels"]),
              let json = await getJSON(url),
              let rels = json["relations"] as? [[String: Any]] else { return [] }
        var out: [MBRelatedArtist] = []
        var seen = Set<String>()
        for rel in rels {
            guard let type = rel["type"] as? String,
                  let a = rel["artist"] as? [String: Any],
                  let id = a["id"] as? String, let nm = a["name"] as? String,
                  seen.insert(id).inserted else { continue }
            out.append(MBRelatedArtist(name: nm, mbid: id, relation: type))
        }
        return out
    }

    // MARK: - HTTP (mirrors AnalyzerCore/MusicBrainzClient)

    private func getJSON(_ url: URL) async -> [String: Any]? {
        for attempt in 0..<2 {
            await awaitSlot()
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
            if code == 503, attempt == 0 { try? await Task.sleep(nanoseconds: 2_000_000_000); continue }
            return nil
        }
        return nil
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
        var items = [URLQueryItem(name: "fmt", value: "json")]
        items.append(contentsOf: query.map { URLQueryItem(name: $0.key, value: $0.value) })
        comp?.queryItems = items
        return comp?.url
    }

    private func lucene(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "+-&|!(){}[]^\"~*?:\\/".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return "\"\(out)\""
    }
}
