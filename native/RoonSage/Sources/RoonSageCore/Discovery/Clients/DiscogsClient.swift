import Foundation

// MARK: - Discogs client for the discovery pipeline (F7 — Discogs Labels producer)
//
// A focused, RoonSageCore-local Discogs client for DiscogsLabelsProducer. Auth is
// a single personal access token (Settings → Externe diensten → Discogs) — the
// simple token-header scheme Discogs documents for a single self-hosted user,
// not the full OAuth1 dance meant for multi-user third-party apps. Mirrors
// MusicBrainzDiscoveryClient's shape: rate-limit pacing (Discogs allows 60/min
// authenticated; paced conservatively well under that), descriptive User-Agent,
// retry-once on throttle, and a per-run cache so a daily batch's repeated
// lookups don't re-hit the service.
public actor DiscogsClient {
    public static let shared = DiscogsClient()

    private let base = "https://api.discogs.com"
    private let userAgent: String
    private let minInterval: TimeInterval
    private var nextSlot: Date = .distantPast

    // Per-run caches: seed artist name → its primary label (nil = none found),
    // and label id → its release list — so two seed artists sharing a label (or
    // re-visits within one run) don't re-fetch.
    private var primaryLabelCache: [String: DiscogsLabel?] = [:]
    private var labelReleasesCache: [Int: [DiscogsRelease]] = [:]

    public init(userAgent: String = "RoonSage/2.0 ( https://github.com/georgemvp/roonsage )",
                minInterval: TimeInterval = 1.1) {
        self.userAgent = userAgent
        self.minInterval = max(0, minInterval)
    }

    /// Drop the per-run caches (called at the start of each pipeline run).
    public func resetCache() { primaryLabelCache = [:]; labelReleasesCache = [:] }

    // MARK: - Models

    public struct DiscogsLabel: Sendable {
        public var id: Int
        public var name: String
    }

    public struct DiscogsRelease: Sendable {
        public var artist: String
        public var title: String
        public var year: Int?
    }

    // MARK: - Primary label for a seed artist

    /// The primary label behind ONE release by `artist`, found via a release
    /// search. "Primary" = Discogs `entity_type == "1"` (a true Label, not a
    /// Series/pressing-plant/studio credit also listed on the release) and
    /// first among those — Discogs convention lists the primary label first.
    /// Cached by artist name. Nil when the artist isn't found on Discogs, has no
    /// release, or the release lists no true label.
    public func primaryLabel(forArtist artist: String, token: String) async -> DiscogsLabel? {
        let key = artist.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        if let cached = primaryLabelCache[key] { return cached }
        let label = await fetchPrimaryLabel(artist: artist, token: token)
        primaryLabelCache[key] = label
        return label
    }

    private func fetchPrimaryLabel(artist: String, token: String) async -> DiscogsLabel? {
        guard let searchURL = url("/database/search", query: ["q": artist, "type": "release", "per_page": "1"]),
              let searchJSON = await getJSON(searchURL, token: token),
              let results = searchJSON["results"] as? [[String: Any]],
              let releaseID = results.first?["id"] as? Int else { return nil }

        guard let releaseURL = url("/releases/\(releaseID)", query: [:]),
              let releaseJSON = await getJSON(releaseURL, token: token),
              let labels = releaseJSON["labels"] as? [[String: Any]] else { return nil }

        for l in labels {
            guard (l["entity_type"] as? String) == "1",
                  let id = l["id"] as? Int, let name = l["name"] as? String else { continue }
            return DiscogsLabel(id: id, name: name)
        }
        return nil
    }

    // MARK: - A label's releases (the actual discovery surface)

    /// Up to `limit` releases from `label`, in the order Discogs returns them.
    /// Cached by label id.
    public func releases(forLabel label: DiscogsLabel, limit: Int, token: String) async -> [DiscogsRelease] {
        if let cached = labelReleasesCache[label.id] { return Array(cached.prefix(limit)) }
        guard let url = url("/labels/\(label.id)/releases", query: ["per_page": "\(limit)"]),
              let json = await getJSON(url, token: token),
              let arr = json["releases"] as? [[String: Any]] else {
            labelReleasesCache[label.id] = []
            return []
        }
        let out = arr.compactMap { r -> DiscogsRelease? in
            guard let artist = r["artist"] as? String, let title = r["title"] as? String else { return nil }
            return DiscogsRelease(artist: artist, title: title, year: r["year"] as? Int)
        }
        labelReleasesCache[label.id] = out
        return Array(out.prefix(limit))
    }

    // MARK: - HTTP (mirrors MusicBrainzDiscoveryClient's shape)

    private func getJSON(_ url: URL, token: String) async -> [String: Any]? {
        for attempt in 0..<2 {
            await awaitSlot()
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
            // 429 = Discogs's rate-limit-exceeded; 503 = transient — both worth one retry.
            if (code == 429 || code == 503), attempt == 0 { try? await Task.sleep(nanoseconds: 2_000_000_000); continue }
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
        comp?.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comp?.url
    }
}
