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

        try migrator.migrate(db)
    }
}
