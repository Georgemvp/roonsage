import Accelerate
import Foundation

/// "Vergelijkbare artiesten in je bibliotheek" — LMS's medoid + Chamfer
/// two-stage ranking over the CLAP embeddings, per artist instead of per track.
///
///  - **Medoid**, not centroid: each artist is represented by the *actual
///    track vector* minimizing summed distance to the artist's other tracks —
///    no out-of-distribution average when an artist spans styles.
///  - **Stage 1** prefilters all artists by medoid↔medoid cosine (cheap).
///  - **Stage 2** re-ranks the survivors with a symmetric Chamfer similarity
///    over the full (capped) vector sets — two artists match when their tracks
///    *mutually* find close neighbours, which captures catalogue overlap far
///    better than one average vector.
///
/// Pure + deterministic; run off-main (a few million vDSP dots on a big
/// library). No network, no Last.fm — this is in-library similarity.
public enum ArtistSimilarity {
    public struct Result: Sendable, Identifiable, Equatable {
        public let name: String     // display name (first casing seen)
        public let score: Double    // symmetric Chamfer cosine, 0…1-ish
        public var id: String { name }
    }

    /// Tunables: cap vectors per artist (deterministic first-N — album order),
    /// stage-1 survivor count, and a floor under which nothing is "similar".
    static let maxTracksPerArtist = 20
    static let prefilterCount = 60
    static let minScore = 0.5

    public static func similarArtists(
        to artist: String,
        tracks: [DatabaseManager.SonicTrack],
        limit: Int = 12
    ) -> [Result] {
        let targetKey = artist.lowercased()
        guard !targetKey.isEmpty else { return [] }

        // Group normalized vectors per artist (display name = first seen).
        var vecsByArtist: [String: [[Float]]] = [:]
        var displayName: [String: String] = [:]
        for t in tracks {
            guard let a = t.artist, !a.isEmpty, let e = t.embedding, !e.isEmpty else { continue }
            let key = a.lowercased()
            if vecsByArtist[key, default: []].count >= maxTracksPerArtist { continue }
            vecsByArtist[key, default: []].append(VectorIndex.normalized(e))
            if displayName[key] == nil { displayName[key] = a }
        }
        guard let targetVecs = vecsByArtist[targetKey], !targetVecs.isEmpty else { return [] }
        let targetMedoid = medoid(of: targetVecs)

        // Stage 1: medoid↔medoid prefilter.
        var stage1: [(key: String, sim: Double)] = []
        stage1.reserveCapacity(vecsByArtist.count)
        for (key, vecs) in vecsByArtist where key != targetKey {
            stage1.append((key, dot(targetMedoid, medoid(of: vecs))))
        }
        stage1.sort { $0.sim > $1.sim }

        // Stage 2: symmetric Chamfer over the survivors' full vector sets.
        var results: [Result] = []
        results.reserveCapacity(min(limit, prefilterCount))
        for cand in stage1.prefix(prefilterCount) {
            guard let vecs = vecsByArtist[cand.key] else { continue }
            let score = chamfer(targetVecs, vecs)
            if score >= minScore {
                results.append(Result(name: displayName[cand.key] ?? cand.key, score: score))
            }
        }
        results.sort { $0.score > $1.score }
        return Array(results.prefix(limit))
    }

    /// The set's member minimizing summed distance (≙ maximizing summed cosine).
    static func medoid(of vecs: [[Float]]) -> [Float] {
        guard vecs.count > 2 else { return vecs[0] }
        var bestIdx = 0
        var bestSum = -Double.infinity
        for i in vecs.indices {
            var sum = 0.0
            for j in vecs.indices where j != i { sum += dot(vecs[i], vecs[j]) }
            if sum > bestSum { bestSum = sum; bestIdx = i }
        }
        return vecs[bestIdx]
    }

    /// Symmetric Chamfer similarity: mean over A of the best match in B,
    /// averaged with the reverse direction.
    static func chamfer(_ a: [[Float]], _ b: [[Float]]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        func directed(_ from: [[Float]], _ to: [[Float]]) -> Double {
            var total = 0.0
            for v in from {
                var best = -Double.infinity
                for w in to { best = max(best, dot(v, w)) }
                total += best
            }
            return total / Double(from.count)
        }
        return (directed(a, b) + directed(b, a)) / 2
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Double {
        var d: Float = 0
        vDSP_dotpr(a, 1, b, 1, &d, vDSP_Length(min(a.count, b.count)))
        return Double(d)
    }
}
