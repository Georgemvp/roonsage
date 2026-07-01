import Foundation
import GRDB

// MARK: - "Ontdek Wekelijks" persistence (server-of-record)
//
// One row per ISO week in `discover_weekly` (see Schema v27). The tracklist is
// stored DENORMALIZED (title/artist/album per track), so the playlist survives a
// Roon resync — which wipes `tracks` — and stays replayable by re-resolving
// title+artist, exactly like saved playlists. Thin clients never touch this table;
// they pull the built playlist over `/discover-weekly`.
extension DatabaseManager {

    /// Insert or replace the weekly playlist for its ISO week (idempotent per week).
    public func upsertDiscoverWeekly(_ pl: DiscoverWeeklyPlaylist) async throws {
        let seedsJSON = Self.jsonString(pl.seedMatchKeys, fallback: "[]")
        let tracksJSON = Self.jsonString(pl.tracks, fallback: "[]")
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO discover_weekly
                    (week_key, generated_at, title, description, image_key, seed_match_keys, tracks)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(week_key) DO UPDATE SET
                    generated_at = excluded.generated_at,
                    title        = excluded.title,
                    description  = excluded.description,
                    image_key    = excluded.image_key,
                    seed_match_keys = excluded.seed_match_keys,
                    tracks       = excluded.tracks
                """,
                arguments: [pl.weekKey, pl.generatedAt, pl.title, pl.description,
                            pl.imageKey, seedsJSON, tracksJSON])
        }
    }

    /// The most recently generated weekly playlist, or nil if none built yet.
    public func latestDiscoverWeekly() async throws -> DiscoverWeeklyPlaylist? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM discover_weekly ORDER BY generated_at DESC LIMIT 1")
            else { return nil }
            return Self.decodeDiscoverWeekly(row)
        }
    }

    /// The weekly playlist for a specific ISO week key, if present.
    public func discoverWeeklyForWeek(_ weekKey: String) async throws -> DiscoverWeeklyPlaylist? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM discover_weekly WHERE week_key = ?", arguments: [weekKey])
            else { return nil }
            return Self.decodeDiscoverWeekly(row)
        }
    }

    // MARK: Helpers

    private static func decodeDiscoverWeekly(_ row: Row) -> DiscoverWeeklyPlaylist {
        let seeds: [String] = (row["seed_match_keys"] as String?)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let tracks: [DiscoverWeeklyTrack] = (row["tracks"] as String?)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([DiscoverWeeklyTrack].self, from: $0) } ?? []
        return DiscoverWeeklyPlaylist(
            weekKey: row["week_key"] ?? "",
            generatedAt: row["generated_at"] ?? "",
            title: row["title"] ?? "",
            description: row["description"] ?? "",
            imageKey: row["image_key"],
            seedMatchKeys: seeds,
            tracks: tracks)
    }

    private static func jsonString<T: Encodable>(_ value: T, fallback: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let s = String(data: data, encoding: .utf8) else { return fallback }
        return s
    }
}
