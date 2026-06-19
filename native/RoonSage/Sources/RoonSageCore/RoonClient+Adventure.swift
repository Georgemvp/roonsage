import AudioAnalysis
import Foundation

@MainActor
extension RoonClient {
    // MARK: - Sonic Adventure
    //
    // A *journey* rather than a station: starting from a seed track, drift through
    // sonic space all the way to a deliberately distant destination, with every
    // hop a smooth transition. Reuses the embedding-aware SongPaths walker over the
    // CLAP index, so the voyage glides from where you are now to somewhere new
    // instead of orbiting one centroid. A one-shot ~`steps`-track expedition.

    /// Start a Sonic Adventure from a now-playing track (resolved by content key).
    public func playSonicAdventure(title: String, artist: String?, album: String?,
                                   steps: Int = 40, zoneID: String) async {
        await playSonicAdventure(
            fromMatchKey: TrackIdentity.matchKey(artist: artist, album: album, title: title),
            steps: steps, zoneID: zoneID)
    }

    /// Build and play a journey from `matchKey` to the most sonically distant
    /// region of the library, smoothed into a flowing path.
    public func playSonicAdventure(fromMatchKey matchKey: String, steps: Int = 40, zoneID: String) async {
        guard let db = database, !matchKey.isEmpty else { return }
        let lib = await radioLibrary()
        guard let index = await activeIndex(db) else {
            lastActionError = ActionError(
                message: "Sonische reis heeft sonische analyse nodig — analyseer eerst je bibliotheek.")
            return
        }
        let disliked = dislikedMatchKeys
        guard let seed = lib.first(where: { $0.matchKey == matchKey }),
              index.embedding(forId: seed.id) != nil else {
            lastActionError = ActionError(
                message: "Sonische reis kan hier niet starten — deze track is nog niet sonisch geanalyseerd.")
            return
        }

        let journey = await Task.detached { () -> [TrackRecord] in
            guard let seedEmb = index.embedding(forId: seed.id) else { return [] }
            // Destination = the most sonically *opposite* track: nearest to −seed.
            // Skip the seed itself and anything thumbed-down.
            let neg = seedEmb.map { -$0 }
            guard let dest = index.nearest(to: neg, k: 8, excludingIds: [seed.id])
                .first(where: { !disliked.contains($0.track.matchKey) })?.track else { return [] }

            // Route only through tracks the user hasn't rejected.
            let candidates = lib.filter { !disliked.contains($0.matchKey) }
            let path = SongPaths.find(from: seed, to: dest, library: candidates,
                                      maxSteps: max(4, steps), index: index)

            // Dedup by content (same song on several albums) keeping path order.
            var seen = Set<String>()
            var out: [TrackRecord] = []
            for step in path {
                let key = step.track.matchKey.isEmpty ? step.track.id : step.track.matchKey
                if seen.insert(key).inserted {
                    out.append(TrackRecord(id: step.track.id, title: step.track.title,
                                           artist: step.track.artist, album: step.track.album))
                }
            }
            return out
        }.value

        guard journey.count >= 2 else {
            lastActionError = ActionError(
                message: "Sonische reis kon geen route vinden — analyseer wat meer muziek.")
            return
        }
        await curateTracks(journey, zoneID: zoneID)
    }
}
