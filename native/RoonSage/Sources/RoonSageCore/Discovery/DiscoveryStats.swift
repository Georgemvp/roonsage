import Foundation

// MARK: - Discovery stats (pure — unit-tested in DiscoveryStatsTests)
//
// Turns raw persistence facts into the "Ontdek-inzichten" dashboard DTO. Kept
// pure (no DB/network) so the aggregation — approval rate, per-producer accept
// rate, genre trend — is fully unit-testable. The DB layer supplies the inputs
// (DatabaseManager.discoveryStatsInputs); RoonClient.discoveryStats wires them.

public enum DiscoveryStatsBuilder {

    /// The minimal per-item facts the aggregation needs — one per retained
    /// recommendation item (across all kept batches).
    public struct ItemFacts: Sendable {
        public var status: String       // "pending" | "accepted" | "rejected"
        public var producers: [String]  // stable producer ids that surfaced it
        public var genres: [String]
        public init(status: String, producers: [String], genres: [String]) {
            self.status = status; self.producers = producers; self.genres = genres
        }
    }

    /// Compose the dashboard DTO. `lifetimeAccepted`/`lifetimeRejected` are the
    /// persistent, prune-proof headline counts; `items` are the retained batches'
    /// items (the only item-level history kept) and drive the recent breakdowns.
    public static func build(items: [ItemFacts],
                             lifetimeAccepted: Int,
                             lifetimeRejected: Int,
                             latestPending: Int,
                             generatedAt: String) -> DiscoveryStatsDTO {
        let decisions = lifetimeAccepted + lifetimeRejected
        let approval = decisions > 0 ? Double(lifetimeAccepted) / Double(decisions) : 0

        // Per-producer tallies. A producer is counted once per item even if it
        // appears twice in that item's sources.
        var contrib: [String: Int] = [:], acc: [String: Int] = [:], rej: [String: Int] = [:]
        for it in items {
            for p in Set(it.producers) where !p.isEmpty {
                contrib[p, default: 0] += 1
                if it.status == "accepted" { acc[p, default: 0] += 1 }
                else if it.status == "rejected" { rej[p, default: 0] += 1 }
            }
        }
        let producers = contrib.keys.map { p -> DiscoveryStatsDTO.ProducerStat in
            let a = acc[p] ?? 0, r = rej[p] ?? 0
            let rate = (a + r) > 0 ? Double(a) / Double(a + r) : nil
            return .init(producer: p, contributions: contrib[p] ?? 0, accepted: a, rejected: r, acceptRate: rate)
        }
        // Producers with a real accept-rate first (best-performing on top), then
        // the "no decisions yet" ones by how much they contribute. Deterministic
        // ties broken by name so the ordering is stable across runs.
        .sorted { lhs, rhs in
            switch (lhs.acceptRate, rhs.acceptRate) {
            case let (l?, r?):
                if l != r { return l > r }
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
            if lhs.contributions != rhs.contributions { return lhs.contributions > rhs.contributions }
            return lhs.producer < rhs.producer
        }

        // Genre trend: count genres among ACCEPTED items; fall back to all retained
        // items when nothing's been saved yet, so day-one isn't blank.
        let accepted = items.filter { $0.status == "accepted" }
        let genreSource = accepted.isEmpty ? items : accepted
        var genreCounts: [String: Int] = [:]
        for it in genreSource {
            for g in Set(it.genres.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }) where !g.isEmpty {
                genreCounts[g, default: 0] += 1
            }
        }
        let topGenres = genreCounts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(6)
            .map { DiscoveryStatsDTO.GenreStat(genre: $0.key, count: $0.value) }

        return DiscoveryStatsDTO(
            accepted: lifetimeAccepted, rejected: lifetimeRejected, pending: latestPending,
            approvalRate: approval, producers: producers, topGenres: Array(topGenres),
            generatedAt: generatedAt)
    }
}
