import GRDB

enum Schema {
    static func migrate(_ db: DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "tracks", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("title",     .text).notNull()
                t.column("artist",    .text)
                t.column("album",     .text)
                t.column("album_key", .text)
                t.column("year",      .integer)
                t.column("is_live",   .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "track_genres", ifNotExists: true) { t in
                t.column("track_id", .text).notNull().references("tracks", onDelete: .cascade)
                t.column("genre",    .text).notNull()
                t.primaryKey(["track_id", "genre"])
            }

            try db.create(table: "sync_state", ifNotExists: true) { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_tracks_artist    ON tracks(artist)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_tracks_album_key ON tracks(album_key)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_tracks_title     ON tracks(title)")
        }

        migrator.registerMigration("v2_listening_history") { db in
            try db.create(table: "listening_history", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title",      .text).notNull()
                t.column("artist",     .text)
                t.column("album",      .text)
                t.column("zone_id",    .text)
                t.column("zone_name",  .text)
                t.column("played_at",  .text).notNull()
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_listen_played_at ON listening_history(played_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_listen_artist     ON listening_history(artist)")
        }

        migrator.registerMigration("v3_playlists") { db in
            try db.create(table: "playlists", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name",       .text).notNull()
                t.column("created_at",  .text).notNull()
            }
            // Track metadata is denormalised so saved playlists survive a resync,
            // where Roon item_keys (tracks.id) change. track_id is a best-effort
            // hint; playback re-resolves by title+artist against the current cache.
            try db.create(table: "playlist_tracks", ifNotExists: true) { t in
                t.column("playlist_id", .integer).notNull()
                    .references("playlists", onDelete: .cascade)
                t.column("position",    .integer).notNull()
                t.column("track_id",    .text)
                t.column("title",       .text).notNull()
                t.column("artist",      .text)
                t.column("album",       .text)
                t.column("album_key",   .text)
                t.column("year",        .integer)
                t.column("is_live",     .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_playlist_tracks_pl ON playlist_tracks(playlist_id, position)")
        }

        migrator.registerMigration("v4_audio_features") { db in
            // Content match key on tracks → join to externally-analyzed features
            // (survives resyncs; populated during sync).
            try db.alter(table: "tracks") { t in
                t.add(column: "match_key", .text)
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_tracks_match_key ON tracks(match_key)")

            // Audio features synced from the native analyzer, keyed by match_key.
            try db.create(table: "track_audio_features", ifNotExists: true) { t in
                t.primaryKey("match_key", .text)
                t.column("bpm",       .double)
                t.column("camelot",   .text)
                t.column("key_root",  .text)
                t.column("key_mode",  .text)
                t.column("energy",    .double)
                t.column("duration",  .double)
                t.column("tags",      .text)      // JSON array
                t.column("synced_at", .text)
            }
        }

        try migrator.migrate(db)
    }
}
