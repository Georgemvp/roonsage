import Foundation

// MARK: - ListenBrainz-Radio producer
//
// ListenBrainz's OWN similarity graph (independent of Last.fm) via two real
// endpoints: Artist Radio (`/1/lb-radio/artist/{mbid}`, seeded on top/liked
// artists) and Similar-Users (`/1/user/{username}/similar-users` → their top
// artists — the LB social graph, a different angle than artist-to-artist
// similarity). NOT implemented: Tag Radio — it returns recordings, not artists,
// requiring a per-recording MusicBrainz lookup (a second rate-limited resolve
// pass); scoped out for now, see native/ROADMAP.md.

public struct ListenBrainzRadioProducer: DiscoveryProducer {
    public let id = "listenbrainz-radio"

    /// Cap on seed artists for Artist Radio — each needs an MB resolve (if not
    /// already an MBID) THEN an LB radio call, both rate-limited/sequential.
    private let maxArtistSeeds = 6
    private let maxSimilarUsers = 3
    private let maxPerSimilarUser = 10

    public init() {}

    public func isEnabled(_ context: ProducerContext) -> Bool { context.listenBrainz != nil }

    public func discover(seeds: DiscoverySeeds, context: ProducerContext) async -> [Candidate] {
        guard let creds = context.listenBrainz else { return [] }
        let disliked = Set(seeds.dislikedArtists.map { $0.lowercased() })
        var byMbid: [String: Candidate] = [:]

        // Artist Radio: seed on liked-first, then top-played artists.
        var seedList: [String] = []
        var seen = Set<String>()
        for a in seeds.likedArtists + seeds.topArtists {
            let k = a.lowercased()
            guard !k.isEmpty, !disliked.contains(k), seen.insert(k).inserted else { continue }
            seedList.append(a)
            if seedList.count >= maxArtistSeeds { break }
        }
        for seed in seedList {
            guard let match = await context.musicBrainz.resolveArtist(name: seed) else { continue }
            let radio = await ListenBrainzClient.shared.artistRadio(mbid: match.mbid, mode: .medium, token: creds.token ?? "")
            for r in radio {
                let key = r.name.lowercased().trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !seeds.libraryArtists.contains(key), !disliked.contains(key) else { continue }
                let existing = byMbid[r.mbid]
                if existing == nil || (existing!.similarity ?? 0) < r.score {
                    byMbid[r.mbid] = Candidate(kind: .artist, artist: r.name, similarity: r.score, producer: id, artistMbid: r.mbid)
                }
            }
        }

        // Similar-Users: the LB social graph — a few similar listeners' top artists.
        if let token = creds.token, !token.isEmpty {
            let users = await ListenBrainzClient.shared.similarUsers(username: creds.username, token: token)
            for u in users.prefix(maxSimilarUsers) {
                let top = await ListenBrainzClient.shared.topArtists(username: u.username, range: "month", token: token)
                for a in top.prefix(maxPerSimilarUser) {
                    let key = a.name.lowercased().trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty, !seeds.libraryArtists.contains(key), !disliked.contains(key) else { continue }
                    // Keyed by name (mbid often absent from user-stats) so it still
                    // dedupes against itself across similar users; a real mbid, when
                    // present, is preferred as the key for a tighter dedupe.
                    let dedupeKey = a.mbid ?? "name:\(key)"
                    guard byMbid[dedupeKey] == nil else { continue }
                    let score = max(0.3, u.similarity * 0.8)
                    byMbid[dedupeKey] = Candidate(kind: .artist, artist: a.name, similarity: score, producer: id, artistMbid: a.mbid)
                }
            }
        }

        return Array(byMbid.values
            .sorted { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
            .prefix(context.perProducerLimit))
    }
}
