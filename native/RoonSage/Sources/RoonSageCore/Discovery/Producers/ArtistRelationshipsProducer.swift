import Foundation

// MARK: - Artist-Relationships producer
//
// MusicBrainz's collaboration graph: band members, side-projects and direct
// collaborators of artists you already like. A different discovery ANGLE than
// sonic similarity — the connection is documented fact, not taste-inferred — so
// candidates carry a flat, moderate similarity rather than a graded score.

public struct ArtistRelationshipsProducer: DiscoveryProducer {
    public let id = "artist-relationships"

    /// Relation types that denote an actual musical link between two artists (not
    /// e.g. "engineer", "producer", "artist and repertoire" — administrative/
    /// production credits that don't imply "you might like this artist too").
    private static let musicalRelations: Set<String> = ["member of band", "collaboration"]

    private let maxSeeds = 10
    private let similarity = 0.55

    public init() {}

    public func isEnabled(_ context: ProducerContext) -> Bool { true }

    public func discover(seeds: DiscoverySeeds, context: ProducerContext) async -> [Candidate] {
        let disliked = Set(seeds.dislikedArtists.map { $0.lowercased() })
        var seedList: [String] = []
        var seen = Set<String>()
        for a in seeds.likedArtists + seeds.topArtists {
            let k = a.lowercased()
            guard !k.isEmpty, !disliked.contains(k), seen.insert(k).inserted else { continue }
            seedList.append(a)
            if seedList.count >= maxSeeds { break }
        }
        guard !seedList.isEmpty else { return [] }

        var byMbid: [String: Candidate] = [:]
        for seed in seedList {
            guard let match = await context.musicBrainz.resolveArtist(name: seed) else { continue }
            let related = await context.musicBrainz.relatedArtists(artistMbid: match.mbid)
            for r in related where Self.musicalRelations.contains(r.relation) {
                let key = r.name.lowercased().trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !seeds.libraryArtists.contains(key), !disliked.contains(key),
                      byMbid[r.mbid] == nil else { continue }
                byMbid[r.mbid] = Candidate(kind: .artist, artist: r.name, similarity: similarity,
                                           producer: id, artistMbid: r.mbid)
            }
        }
        return Array(byMbid.values.prefix(context.perProducerLimit))
    }
}
