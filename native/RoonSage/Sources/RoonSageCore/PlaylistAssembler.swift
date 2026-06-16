import Foundation

/// Deterministic post-LLM curation pass. The generation LLM picks track numbers
/// but only *asks* it to respect "max 2 per artist · no consecutive same artist
/// · variety", and silently returns fewer than requested when it emits invalid
/// numbers. This assembler guarantees those properties in code, independent of
/// model compliance: it deduplicates, enforces the per-artist cap, spreads
/// artists so none sit back-to-back, and tops the set up to the target from the
/// (sonically-ranked) candidate pool when the LLM under-delivers.
///
/// Soft signals — preferred artists (from listening history) and recently-used
/// identities (anti-repetition across generations) — only influence top-up
/// order and tie-breaks; they never displace an actual LLM pick.
///
/// Pure + side-effect-free so it's directly unit-testable, mirroring
/// `RoonClient.rankCandidates`.
public enum PlaylistAssembler {

    /// Stable identity for dedup / anti-repetition. Prefers the content match
    /// key; falls back to title|artist so tracks without a key still dedup.
    public static func identity(_ t: TrackRecord) -> String {
        if let mk = t.matchKey, !mk.isEmpty { return mk }
        return "\(t.title.lowercased())|\((t.artist ?? "").lowercased())"
    }

    /// Lowercased artist used for the per-artist cap + consecutive check. Returns
    /// nil for blank artists so they're never capped or treated as "the same".
    static func artistKey(_ t: TrackRecord) -> String? {
        let a = (t.artist ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? nil : a
    }

    public static func assemble(
        llmPicks: [TrackRecord],
        pool: [TrackRecord],
        target: Int,
        maxPerArtist: Int = 2,
        preferredArtists: Set<String> = [],
        deprioritized: Set<String> = []
    ) -> [TrackRecord] {
        guard target > 0 else { return [] }

        // 1. Priority-ordered, de-duplicated eligible list: the LLM's picks first
        //    (it curated for *this* request), then the pool as top-up material.
        //    Within the pool only: float preferred-artist tracks slightly forward
        //    and push recently-used identities to the back — a stable sort so the
        //    sonic ranking order is otherwise preserved.
        let sortedPool = pool.enumerated().sorted { lhs, rhs in
            let l = lhs.element, r = rhs.element
            let lRecent = deprioritized.contains(identity(l))
            let rRecent = deprioritized.contains(identity(r))
            if lRecent != rRecent { return !lRecent }                 // fresh before recent
            let lPref = artistKey(l).map(preferredArtists.contains) ?? false
            let rPref = artistKey(r).map(preferredArtists.contains) ?? false
            if lPref != rPref { return lPref }                        // preferred before rest
            return lhs.offset < rhs.offset                            // else keep rank order
        }.map(\.element)

        var seen = Set<String>()
        var eligible: [TrackRecord] = []
        eligible.reserveCapacity(llmPicks.count + sortedPool.count)
        for t in llmPicks + sortedPool where seen.insert(identity(t)).inserted {
            eligible.append(t)
        }

        // 2. Greedy selection: walk the eligible list in priority order, taking the
        //    first track that is under the per-artist cap AND not the same artist
        //    as the previous pick. If only same-artist candidates remain (variety
        //    impossible), take the first under-cap one so we still hit the target.
        var result: [TrackRecord] = []
        var artistCount: [String: Int] = [:]
        var lastArtist: String?
        var remaining = eligible

        while result.count < target, !remaining.isEmpty {
            var chosen: Int?
            var fallback: Int?
            for (i, t) in remaining.enumerated() {
                let ak = artistKey(t)
                if let ak, (artistCount[ak] ?? 0) >= maxPerArtist { continue }   // over cap
                if fallback == nil { fallback = i }
                if ak == nil || ak != lastArtist { chosen = i; break }           // avoids back-to-back
            }
            guard let pick = chosen ?? fallback else { break }   // nothing left under cap
            let t = remaining.remove(at: pick)
            result.append(t)
            if let ak = artistKey(t) { artistCount[ak, default: 0] += 1; lastArtist = ak }
            else { lastArtist = nil }
        }
        return result
    }
}
