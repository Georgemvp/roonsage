import AudioAnalysis
import Foundation
import GRDB

/// Artist-page data (LMS-style "Artiestpagina 2.0"): biography, most-played
/// tracks, and in-library similar artists. All three degrade to empty when
/// their source is unavailable — the page renders what it has.
@MainActor
extension RoonClient {

    // MARK: - Biography (Last.fm, cached in the DB for 30 days)

    public func artistBio(name: String) async -> String? {
        guard !name.isEmpty else { return nil }
        let key = name.lowercased()
        if let db = database {
            let cached = await db.cachedArtistBio(artistKey: key, maxAgeDays: 30)
            switch cached {
            case .fresh(let bio): return bio     // bio may be nil = known-absent
            case .stale, .missing: break
            }
        }
        guard let apiKey = KeychainStore.load(key: "lastfm_api_key"), !apiKey.isEmpty else { return nil }
        let bio = await LastfmClient.shared.getArtistBio(artist: name, apiKey: apiKey)
        if let db = database {
            await db.saveArtistBio(artistKey: key, bio: bio)  // negative results cache too
        }
        return bio
    }

    // MARK: - Most-played tracks of one artist

    /// Play stats are keyed by content match_key, which *starts with* the
    /// normalized primary artist — so one prefix scan gives this artist's
    /// stats, on thin clients (server /play-stats) exactly like on the server.
    public func topPlayedTracks(artist: String, limit: Int = 5) async -> [DatabaseManager.LibraryTrackRow] {
        let prefix = TrackIdentity.matchKey(artist: artist, album: nil, title: nil)
        guard prefix.count > 1 else { return [] }
        let stats = await playStats()
        let keys = stats.filter { $0.matchKey.hasPrefix(prefix) }
            .sorted { $0.count > $1.count }
            .prefix(limit * 2)                  // a key may miss a library row
            .map(\.matchKey)
        let rows = await tracksByMatchKeys(Array(keys))
        return Array(rows.prefix(limit))
    }

    // MARK: - Similar artists in the library (medoid + Chamfer on embeddings)

    public func similarLibraryArtists(to name: String, limit: Int = 12) async -> [ArtistSimilarity.Result] {
        guard let db = database else { return [] }
        let tracks = await sonicCache.tracks(from: db)
        guard !tracks.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            ArtistSimilarity.similarArtists(to: name, tracks: tracks, limit: limit)
        }.value
    }
}

extension DatabaseManager {
    public enum CachedBio: Sendable {
        case fresh(String?)   // within TTL; associated bio (nil = known-absent)
        case stale
        case missing
    }

    public func cachedArtistBio(artistKey: String, maxAgeDays: Int) async -> CachedBio {
        (try? await pool.read { db -> CachedBio in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT bio, fetched_at FROM artist_bio WHERE artist_key = ?",
                arguments: [artistKey]) else { return .missing }
            let fetched = (row["fetched_at"] as String?).flatMap { Self.isoFormatter.date(from: $0) }
            let age = fetched.map { Date().timeIntervalSince($0) } ?? .infinity
            return age < Double(maxAgeDays) * 86_400 ? .fresh(row["bio"]) : .stale
        }) ?? .missing
    }

    public func saveArtistBio(artistKey: String, bio: String?) async {
        let now = Self.isoFormatter.string(from: Date())
        try? await pool.write { db in
            try db.execute(sql: """
                INSERT INTO artist_bio (artist_key, bio, fetched_at) VALUES (?,?,?)
                ON CONFLICT(artist_key) DO UPDATE SET bio=excluded.bio, fetched_at=excluded.fetched_at
                """, arguments: [artistKey, bio, now])
        }
    }
}
