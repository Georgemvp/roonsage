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

        try migrator.migrate(db)
    }
}
