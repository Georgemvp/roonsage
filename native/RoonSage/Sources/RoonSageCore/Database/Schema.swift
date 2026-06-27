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

        migrator.registerMigration("v14_listen_source") { db in
            // Onderscheid lokaal gelogde Roon-listens van geïmporteerde Last.fm-
            // scrobbles, zodat we de import idempotent kunnen herbouwen.
            try db.execute(sql: "ALTER TABLE listening_history ADD COLUMN source TEXT NOT NULL DEFAULT 'roon'")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_listen_source ON listening_history(source)")
        }

        migrator.registerMigration("v15_clap_embeddings") { db in
            // CLAP sonic embedding pulled from the analyzer (Track E5). embedding
            // is a packed Float32 BLOB; map_x/map_y hold the PCA-2D projection.
            try db.execute(sql: "ALTER TABLE track_audio_features ADD COLUMN embedding BLOB")
            try db.execute(sql: "ALTER TABLE track_audio_features ADD COLUMN moods TEXT")
            try db.execute(sql: "ALTER TABLE track_audio_features ADD COLUMN map_x REAL")
            try db.execute(sql: "ALTER TABLE track_audio_features ADD COLUMN map_y REAL")
        }

        // Explicit like/dislike feedback on tracks, so radios, the Sonic
        // Fingerprint and album recommendations learn the user's taste beyond
        // implicit play counts. Keyed by content `match_key` (TrackIdentity) so a
        // thumb survives library resyncs and joins the analyzed library — one row
        // per track, latest verdict wins (re-tap toggles/clears it). Lives on the
        // server-of-record; thin clients pull it over /feedback.
        migrator.registerMigration("v16_track_feedback") { db in
            try db.create(table: "track_feedback", ifNotExists: true) { t in
                t.primaryKey("match_key", .text)
                t.column("title",      .text)
                t.column("artist",     .text)
                t.column("kind",       .text).notNull()   // "like" | "dislike"
                t.column("updated_at", .text).notNull()
            }
        }

        // One-time cleanup of double-counted scrobbles: Roon scrobbles its own
        // plays to Last.fm, so older incremental syncs imported a "lastfm" row
        // alongside the "roon" row we already logged locally (a few minutes
        // apart). Drop the Last.fm copy when a same-track non-lastfm listen sits
        // within a 10-minute window. (Future syncs avoid this via
        // appendDedupedScrobbles.)
        migrator.registerMigration("v17_dedupe_lastfm_vs_roon") { db in
            try db.execute(sql: """
                DELETE FROM listening_history
                WHERE source = 'lastfm'
                  AND EXISTS (
                    SELECT 1 FROM listening_history r
                    WHERE r.source <> 'lastfm'
                      AND LOWER(r.artist) = LOWER(listening_history.artist)
                      AND LOWER(r.title)  = LOWER(listening_history.title)
                      AND ABS(CAST(strftime('%s', r.played_at) AS INTEGER)
                            - CAST(strftime('%s', listening_history.played_at) AS INTEGER)) <= 600
                  )
            """)
        }

        // The taste-analysis genre/decade queries join listening_history to tracks
        // on LOWER(title)+LOWER(artist) — history has no stable track key, only
        // strings. Without a matching expression index that join is a full cross
        // scan (tens of thousands of genres × tens of thousands of listens) that
        // grows with history and eventually blows past the client's request
        // timeout (→ "Analyse nog niet beschikbaar"). An expression index on the
        // exact LOWER(title),LOWER(artist) pair turns it into an index search
        // (~250× faster on a 42k-listen / 76k-track library: >25s → ~0.1s).
        migrator.registerMigration("v18_listen_join_index") { db in
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_tracks_lower_title_artist ON tracks(LOWER(title), LOWER(artist))")
        }

        // BPM detection confidence from the analyzer's TempoAnalyzer (already stored
        // analyzer-side; just wasn't propagated). Lets the flow sequencer trust an
        // uncertain tempo less. Backfills on the next feature sync — no re-analysis.
        migrator.registerMigration("v19_bpm_confidence") { db in
            try db.execute(sql: "ALTER TABLE track_audio_features ADD COLUMN bpm_confidence REAL")
        }

        // CLAP zero-shot attribute axes (valence/danceability/acousticness/
        // instrumentalness) as a JSON map, kept separate from `moods` so it never
        // pollutes the Music Map / mood buckets. Populates on the next feature sync
        // once the analyzer has computed them (analysis or the embedding backfill).
        migrator.registerMigration("v20_attributes") { db in
            try db.execute(sql: "ALTER TABLE track_audio_features ADD COLUMN attributes TEXT")
        }

        // External-source playlists (e.g. ListenBrainz). `external_id` carries a
        // stable, source-scoped key ("listenbrainz:<playlist_mbid>") so the daily
        // import can upsert in place instead of piling up a fresh copy each run.
        // NULL for user-curated playlists — SQLite treats NULLs as distinct, so a
        // UNIQUE index still allows any number of them.
        migrator.registerMigration("v21_playlist_external_id") { db in
            try db.alter(table: "playlists") { t in
                t.add(column: "external_id", .text)
            }
            try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_playlists_external_id ON playlists(external_id)")
        }

        // MusicBrainz genre enrichment, synced from the analyzer alongside audio
        // features. Two tables, both keyed so they survive a Roon resync (which
        // clears `tracks`/`track_genres`):
        //   • track_mb_genres — genres per content `match_key` (like
        //     track_audio_features), so MB genres aren't wiped when the Roon
        //     genre pass rewrites track_genres.
        //   • genre_taxonomy — the parent←subgenre hierarchy, so a filter on a
        //     parent genre ("Rock") can expand to its subgenres ("Blues Rock").
        migrator.registerMigration("v22_musicbrainz_genres") { db in
            try db.create(table: "track_mb_genres", ifNotExists: true) { t in
                t.column("match_key", .text).notNull()
                t.column("genre",     .text).notNull()
                t.primaryKey(["match_key", "genre"])
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mb_genres_genre ON track_mb_genres(genre)")

            try db.create(table: "genre_taxonomy", ifNotExists: true) { t in
                t.primaryKey("genre", .text)
                t.column("parent", .text)   // NULL/empty = root genre
                t.column("mbid",   .text)
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_genre_taxonomy_parent ON genre_taxonomy(parent)")
        }

        try migrator.migrate(db)
    }
}
