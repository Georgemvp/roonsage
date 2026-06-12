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

        migrator.registerMigration("v5_track_image_key") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "image_key", .text)   // Roon album-art key, set during sync
            }
        }

        // TrackIdentity.matchKey changed from artist|album|title to artist|title
        // (with Roon track-number prefix + feat. stripping).  Any match_key values
        // stored in the old format won't join against the analyzer's new-format
        // keys — clear them so the next library sync repopulates them correctly.
        migrator.registerMigration("v6_reset_matchkey_format") { db in
            try db.execute(sql: "UPDATE tracks SET match_key = NULL")
        }

        // TrackIdentity gains remaster/edition stripping + LibrarySyncService uses
        // track-level artist for compilations.  Reset so the next sync regenerates
        // match_keys with improved hit rate.
        migrator.registerMigration("v7_reset_matchkey_remaster_and_compilation") { db in
            try db.execute(sql: "UPDATE tracks SET match_key = NULL")
        }

        // LibrarySyncService now strips Roon's disc-track number prefix from stored
        // titles ("1-4 Don't Look Back…" → "Don't Look Back…"). NULL match_keys so
        // the next auto-resync re-stores all titles in the clean format.
        migrator.registerMigration("v8_strip_title_prefix") { db in
            try db.execute(sql: "UPDATE tracks SET match_key = NULL")
        }

        // TrackIdentity.matchKey now reduces the artist to its first credited
        // artist (primaryArtist: cuts feat./ft./featuring + the first , ; / &)
        // so Roon's "A" matches file tags' "A feat. B" / "A & B". NULL match_keys
        // so the next auto-resync regenerates them under the new scheme. The
        // analyzer re-keys its export automatically (FeatureStore.exportJSON
        // recomputes via TrackIdentity), so app + analyzer must ship together.
        migrator.registerMigration("v9_primary_artist_matchkey") { db in
            try db.execute(sql: "UPDATE tracks SET match_key = NULL")
        }

        // Resumable sync: per-album checkpoints instead of a destructive
        // clearTracks() upfront. `album_fp` is a stable album fingerprint
        // (title|subtitle — Roon item_keys are session-scoped and can't key
        // anything persistent); `sync_album_checkpoints` records which albums
        // a sync generation has completed so an interrupted sync resumes
        // instead of restarting.
        migrator.registerMigration("v10_resumable_sync") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "album_fp", .text)
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_tracks_album_fp ON tracks(album_fp)")
            try db.create(table: "sync_album_checkpoints", ifNotExists: true) { t in
                t.primaryKey("fingerprint", .text)
                t.column("generation", .integer).notNull()
            }
        }

        // The sync stored Roon's navigation rows ("Play Album" — one per album,
        // 9.5k phantom tracks on a 9.5k-album library) because it only checked
        // for an item_key. The sync now filters them (no subtitle = navigation);
        // this cleans libraries that synced before the fix. No match_key reset:
        // an auto-resync here would block the iPhone's import-from-Mac flow.
        migrator.registerMigration("v11_drop_navigation_rows") { db in
            try db.execute(sql: "DELETE FROM tracks WHERE title = 'Play Album' OR title = 'Queue Album' OR title = 'Shuffle Album'")
        }

        // Free-text search used leading-wildcard LIKE ('%q%'), which defeats
        // every index → a full table scan per keystroke on large libraries.
        // External-content FTS5 over title/artist/album turns that into an
        // index lookup. Triggers keep it in sync; all tracks writes are plain
        // INSERT / upsert / DELETE (no INSERT OR REPLACE), so the trigger
        // trio covers every mutation path.
        migrator.registerMigration("v12_fts_search") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS tracks_fts USING fts5(
                    title, artist, album,
                    content='tracks', content_rowid='rowid',
                    tokenize="unicode61 remove_diacritics 2"
                )
            """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS tracks_fts_ai AFTER INSERT ON tracks BEGIN
                    INSERT INTO tracks_fts(rowid, title, artist, album)
                    VALUES (new.rowid, new.title, new.artist, new.album);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS tracks_fts_ad AFTER DELETE ON tracks BEGIN
                    INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, album)
                    VALUES ('delete', old.rowid, old.title, old.artist, old.album);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS tracks_fts_au AFTER UPDATE ON tracks BEGIN
                    INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, album)
                    VALUES ('delete', old.rowid, old.title, old.artist, old.album);
                    INSERT INTO tracks_fts(rowid, title, artist, album)
                    VALUES (new.rowid, new.title, new.artist, new.album);
                END
            """)
            try db.execute(sql: """
                INSERT INTO tracks_fts(rowid, title, artist, album)
                SELECT rowid, title, artist, album FROM tracks
            """)
        }

        migrator.registerMigration("v13_recommendation_history") { db in
            try db.create(table: "recommendation_history", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("prompt",     .text).notNull()
                t.column("created_at", .text).notNull()
            }
            // Albums are denormalised so history survives library resyncs.
            try db.create(table: "recommendation_albums", ifNotExists: true) { t in
                t.column("history_id", .integer).notNull()
                    .references("recommendation_history", onDelete: .cascade)
                t.column("position",   .integer).notNull()
                t.column("album_key",  .text).notNull()
                t.column("album",      .text).notNull()
                t.column("artist",     .text)
                t.column("year",       .integer)
                t.column("image_key",  .text)
                t.primaryKey(["history_id", "position"])
            }
        }

        try migrator.migrate(db)
    }
}
