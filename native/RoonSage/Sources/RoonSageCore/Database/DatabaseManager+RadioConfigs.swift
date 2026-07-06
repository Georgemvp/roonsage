import Foundation
import GRDB

// MARK: - Custom radio configs (server-of-record CRUD)
//
// Storage for user-composed `RadioConfig`s. Same shape as the playlists/favorites
// server-of-record tables: the always-on server writes its DB directly; client
// apps reach these over `/radio-configs`. GRDB's Codable record support stores the
// facet arrays as JSON-text columns, so `RadioConfig.fetchAll` / `save` round-trip
// them without hand-rolled encoding.

extension DatabaseManager {

    /// All configs, newest edit first.
    public func listRadioConfigs() async throws -> [RadioConfig] {
        try await pool.read { db in
            try RadioConfig.fetchAll(db, sql: "SELECT * FROM radio_configs ORDER BY updated_at DESC")
        }
    }

    /// Create or update a config (upsert on `id`). Stamps `updated_at` so clients
    /// polling the library revision see the change.
    public func upsertRadioConfig(_ config: RadioConfig) async throws {
        var c = config
        c.updatedAt = Self.isoFormatter.string(from: Date())
        let stamped = c   // immutable copy for the Sendable write closure
        try await pool.write { db in try stamped.save(db) }
    }

    public func deleteRadioConfig(id: String) async throws {
        try await pool.write { db in
            _ = try RadioConfig.deleteOne(db, key: id)
        }
    }

    /// Persist the resolved Qobuz playlist id after a mirror, for rename-in-place.
    public func setRadioConfigQobuzID(id: String, _ qobuzID: String?) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE radio_configs SET qobuz_playlist_id = ? WHERE id = ?",
                           arguments: [qobuzID, id])
        }
    }
}
