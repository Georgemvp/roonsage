import Foundation
import GRDB

// MARK: - Dataset producer (offline MusicMoveArr sidecar)
//
// Reads pre-baked candidate albums from the distilled dataset sidecar
// (`ds_candidates`, built offline by native/scripts/distill-datasets.sh from the
// Deezer/MusicBrainz dumps): albums by artists adjacent to the library's taste
// that we don't own. Zero network cost and no rate limits — the heavy "who is
// adjacent" policy lives in the distill script, so it can iterate without app
// changes. Album-kind, so every candidate flows through the same MB-validate →
// Qobuz-resolve (library-first) → score path as the online producers.
//
// Expected sidecar table:
//     ds_candidates(artist TEXT, album TEXT, year INTEGER,
//                   genres TEXT /* JSON [String] */, fans INTEGER, source TEXT)

public struct DatasetProducer: DiscoveryProducer {
    public let id = "dataset"

    /// Rows fetched from the sidecar before in-memory filtering — bounds the
    /// per-run cost however large the sidecar grows.
    private let fetchCap = 400

    public init() {}

    public func isEnabled(_ context: ProducerContext) -> Bool {
        guard let p = context.datasetSidecarPath, !p.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: p)
    }

    public func discover(seeds: DiscoverySeeds, context: ProducerContext) async -> [Candidate] {
        guard let path = context.datasetSidecarPath,
              let rows = Self.fetchCandidates(path: path, cap: fetchCap) else { return [] }
        let disliked = Set(seeds.dislikedArtists.map { $0.lowercased() })
        var out: [Candidate] = []
        var seenAlbum = Set<String>()
        // Shuffled for run-to-run variety: the sidecar is a static snapshot and a
        // rank-ordered walk would surface the same head forever.
        for r in rows.shuffled() {
            let artistKey = r.artist.lowercased()
            if disliked.contains(artistKey) { continue }
            let key = "\(artistKey)|\(r.album.lowercased())"
            if seeds.libraryAlbumKeys.contains(key) { continue }        // already owned
            guard seenAlbum.insert(key).inserted else { continue }
            out.append(Candidate(kind: .album, artist: r.artist, album: r.album, year: r.year,
                                 genres: r.genres, similarity: r.similarity, producer: id))
            if out.count >= context.perProducerLimit { break }
        }
        return out
    }

    struct SidecarCandidate {
        let artist: String
        let album: String
        let year: Int?
        let genres: [String]
        let similarity: Double
    }

    /// nil on any sidecar problem (unreadable, missing table) — the producer then
    /// contributes nothing, like every other network producer on failure.
    static func fetchCandidates(path: String, cap: Int) -> [SidecarCandidate]? {
        var config = Configuration()
        config.readonly = true
        guard let q = try? DatabaseQueue(path: path, configuration: config) else { return nil }
        return try? q.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT artist, album, year, genres, fans FROM ds_candidates
                ORDER BY fans DESC LIMIT ?
            """, arguments: [cap])
            let maxFans = rows.compactMap { $0["fans"] as Int? }.max() ?? 0
            return rows.compactMap { r in
                guard let artist = r["artist"] as String?, !artist.isEmpty,
                      let album = r["album"] as String?, !album.isEmpty else { return nil }
                var genres: [String] = []
                if let g = r["genres"] as String?, let d = g.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: d) as? [String] { genres = arr }
                let fans = (r["fans"] as Int?) ?? 0
                // Log-scaled fan count → a 0.3…0.9 similarity band: adjacency from
                // the distill script is real but weaker evidence than a direct
                // "similar artist" hit, and zero-fans rows shouldn't zero out.
                let sim = maxFans > 0 ? 0.3 + 0.6 * (log(1 + Double(fans)) / log(1 + Double(maxFans))) : 0.5
                return SidecarCandidate(artist: artist, album: album, year: r["year"],
                                        genres: genres, similarity: sim)
            }
        }
    }
}
