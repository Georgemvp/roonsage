import AudioAnalysis
import Foundation
import GRDB

/// Live measurement of the analyzer↔library match rate on the real databases:
/// the app's `library.db` (Roon-sourced tracks) vs this analyzer's feature store
/// (file-tag-sourced). Reports the old artist|title scheme, the new primary-artist
/// scheme, and the new scheme + fuzzy fallback — so the E1 gain is a number.
public enum MatchChecker {

    private static func oldKey(_ artist: String?, _ title: String?) -> String {
        "\(TrackIdentity.normalise(artist))\u{1f}\(TrackIdentity.normalise(TrackIdentity.cleanTitle(title)))"
    }

    public static func run(libraryDB: String, featureDB: String, fuzzyThreshold: Double = 0.85) throws -> String {
        var ro = Configuration()
        ro.readonly = true

        // Feature side (file tags): build old/new key sets + fuzzy buckets.
        let fq = try DatabaseQueue(path: featureDB, configuration: ro)
        var newKeys = Set<String>(), oldKeys = Set<String>()
        var buckets: [String: [Set<String>]] = [:]
        try fq.read { db in
            for r in try Row.fetchAll(db, sql: "SELECT artist, album, title FROM track_features WHERE bpm IS NOT NULL") {
                let artist = r["artist"] as String?, album = r["album"] as String?, title = r["title"] as String?
                newKeys.insert(TrackIdentity.matchKey(artist: artist, album: album, title: title))
                oldKeys.insert(oldKey(artist, title))
                buckets[TrackIdentity.normalise(TrackIdentity.primaryArtist(artist)), default: []]
                    .append(FuzzyMatch.tokens(title))
            }
        }

        // Library side (Roon): classify each track.
        let lq = try DatabaseQueue(path: libraryDB, configuration: ro)
        var total = 0, oldExact = 0, newExact = 0, fuzzyExtra = 0
        try lq.read { db in
            for r in try Row.fetchAll(db, sql: "SELECT artist, album, title FROM tracks") {
                total += 1
                let artist = r["artist"] as String?, album = r["album"] as String?, title = r["title"] as String?
                if oldKeys.contains(oldKey(artist, title)) { oldExact += 1 }
                if newKeys.contains(TrackIdentity.matchKey(artist: artist, album: album, title: title)) {
                    newExact += 1
                } else {
                    // Would the fuzzy fallback rescue it?
                    let ak = TrackIdentity.normalise(TrackIdentity.primaryArtist(artist))
                    let tokens = FuzzyMatch.tokens(title)
                    if (buckets[ak] ?? []).contains(where: { FuzzyMatch.score(tokens, $0) >= fuzzyThreshold }) {
                        fuzzyExtra += 1
                    }
                }
            }
        }

        func pct(_ n: Int) -> String { total == 0 ? "0%" : String(format: "%.1f%%", Double(n) / Double(total) * 100) }
        let newTotal = newExact + fuzzyExtra
        return """
        Match-rate over \(total) Roon library tracks  (\(newKeys.count) feature keys)
          old (artist|title)        : \(oldExact)  (\(pct(oldExact)))
          new (primary-artist)      : \(newExact)  (\(pct(newExact)))
          new + fuzzy fallback      : \(newTotal)  (\(pct(newTotal)))
          ── gain over old          : +\(newTotal - oldExact)  (+\(String(format: "%.1f", Double(newTotal - oldExact) / Double(max(total,1)) * 100))pp)
        """
    }
}
