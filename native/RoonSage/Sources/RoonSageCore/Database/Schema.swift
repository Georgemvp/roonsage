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

        // Discovery engine (outward-facing recommendations — see Discovery/). A
        // pipeline run stores a *batch* of scored artist/album recommendations that
        // must resolve to Qobuz to be actionable. All additive (no match_key reset),
        // so this does NOT force a Roon resync. Lives on the server-of-record; thin
        // clients pull the feed over /discovery/recommendations and POST accept/reject.
        migrator.registerMigration("v23_discovery_batches") { db in
            try db.create(table: "recommendation_batches", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("created_at", .text).notNull()
                t.column("status",     .text).notNull().defaults(to: "complete")  // running|complete|failed
                t.column("trigger",    .text).notNull().defaults(to: "scheduled") // scheduled|manual
                t.column("item_count", .integer).notNull().defaults(to: 0)
                t.column("taste_sig",  .text)   // taste-vector signature at run time (skip-if-unchanged)
            }

            try db.create(table: "recommendation_items", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("batch_id", .integer).notNull()
                    .references("recommendation_batches", onDelete: .cascade)
                t.column("kind",   .text).notNull()          // artist|album
                t.column("artist", .text).notNull()
                t.column("artist_mbid", .text)
                t.column("album",  .text)                    // NULL for kind=artist
                t.column("release_group_mbid", .text)        // album dedup key
                t.column("year",   .integer)
                t.column("qobuz_album_id", .text)            // Qobuz resolution (album-kind); NULL if unmatched
                t.column("image_url", .text)
                t.column("score",  .double).notNull().defaults(to: 0)
                t.column("score_json",   .text).notNull().defaults(to: "{}")
                t.column("sources_json", .text).notNull().defaults(to: "[]")
                t.column("genres_json",  .text).notNull().defaults(to: "[]")
                t.column("explanation",     .text)           // AI card, cached
                t.column("explanation_sig", .text)
                t.column("status", .text).notNull().defaults(to: "pending")  // pending|accepted|rejected
                t.column("rejected_at", .text)
                t.column("dedup_key",  .text).notNull()
                t.column("created_at", .text).notNull()
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_recitems_batch  ON recommendation_items(batch_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_recitems_status ON recommendation_items(status)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_recitems_dedup  ON recommendation_items(dedup_key)")
        }

        // Artists the user follows for Release-Radar (a producer that surfaces their
        // NEW releases). Populated when an album/artist recommendation is accepted,
        // or manually. `last_seen_rg` records the newest release-group already
        // surfaced so the radar only emits genuinely new ones.
        migrator.registerMigration("v24_artist_watchlist") { db in
            try db.create(table: "artist_watchlist", ifNotExists: true) { t in
                t.primaryKey("artist", .text)          // lowercased canonical name
                t.column("artist_mbid",  .text)
                t.column("display_name", .text).notNull()
                t.column("added_at", .text).notNull()
                t.column("source",   .text).notNull().defaults(to: "accept")  // accept|manual
                t.column("last_seen_rg", .text)
            }
        }

        // Persistent reject memory + cooldown, decoupled from the ephemeral items
        // table (which is pruned as old batches age out). A rejection must outlive
        // the batch it came from so the Filter keeps honouring the cooldown / block.
        migrator.registerMigration("v25_discovery_rejections") { db in
            try db.create(table: "discovery_rejections", ifNotExists: true) { t in
                t.primaryKey("dedup_key", .text)       // same form as recommendation_items.dedup_key
                t.column("kind",   .text).notNull()    // artist|album
                t.column("artist", .text).notNull()
                t.column("album",  .text)
                t.column("rejected_at", .text).notNull()
                t.column("permanent",   .integer).notNull().defaults(to: 0)  // 1 = never show this again
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_rejections_kind ON discovery_rejections(kind)")
        }

        // Deezer global popularity (`rank`), synced from the analyzer's /features
        // export. Steers the smart-radio adventurousness dial toward hits (low
        // dial) or deep cuts (high dial). NULL until the analyzer looks a track up.
        migrator.registerMigration("v26_track_popularity") { db in
            try db.execute(sql: "ALTER TABLE track_audio_features ADD COLUMN popularity INTEGER")
        }

        // "Ontdek Wekelijks" — the library-first weekly discovery playlist. One row
        // per ISO week (idempotent): a stable seed set, an AI title/description, and
        // the fully DENORMALIZED tracklist (title/artist/album per track, plus a
        // `not_in_library` flag for Qobuz/ListenBrainz enrichment picks). Denormalized
        // so the playlist survives a Roon resync (which wipes `tracks`) and stays
        // replayable by re-resolving title+artist — same contract as saved playlists.
        // Lives on the server-of-record; thin clients pull it over /discover-weekly.
        migrator.registerMigration("v27_discover_weekly") { db in
            try db.create(table: "discover_weekly", ifNotExists: true) { t in
                t.primaryKey("week_key", .text)              // ISO week, e.g. "2026-W27"
                t.column("generated_at", .text).notNull()    // ISO8601 build timestamp
                t.column("title",        .text).notNull()
                t.column("description",  .text).notNull()
                t.column("image_key",    .text)
                t.column("seed_match_keys", .text).notNull().defaults(to: "[]")  // JSON [String]
                t.column("tracks",       .text).notNull().defaults(to: "[]")     // JSON [DiscoverWeeklyTrack]
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_discover_weekly_generated ON discover_weekly(generated_at DESC)")
        }

        // F3: perceptual loudness (K-weighted LUFS, BS.1770), synced from the
        // analyzer's /features export. A separate factor in the DJ-set sequencer
        // (alongside BPM/Camelot/energy) to smooth level jumps between tracks. NULL
        // until the analyzer computes it; the DJ builder falls back when absent.
        migrator.registerMigration("v28_track_loudness") { db in
            try db.execute(sql: "ALTER TABLE track_audio_features ADD COLUMN loudness REAL")
        }

        // Lyrics, fetched from LRCLIB on the server-of-record and served to thin
        // clients over /lyrics. Keyed by match_key (like features) so it survives a
        // Roon resync. `synced` holds JSON-encoded [LyricLine] (karaoke); `found`
        // caches a negative lookup so the backfill doesn't retry a track forever.
        migrator.registerMigration("v29_track_lyrics") { db in
            try db.create(table: "track_lyrics", ifNotExists: true) { t in
                t.primaryKey("match_key", .text)
                t.column("plain",        .text)                     // plain lyrics, nullable
                t.column("synced",       .text)                     // JSON [LyricLine], nullable
                t.column("instrumental", .integer).notNull().defaults(to: 0)
                t.column("found",        .integer).notNull().defaults(to: 0)  // 1 = a lookup matched
                t.column("source",       .text)                     // e.g. "lrclib"
                t.column("fetched_at",   .text).notNull()
            }
        }

        // When each track first appeared in this library cache — powers the
        // "Recent toegevoegd" sort (LMS-style browse modes). Every sync path
        // (per-album resync, full import, direct upsert) deletes + reinserts
        // `tracks` rows, so the date lives in a side table keyed by content
        // match_key (the track_mb_genres pattern) and is maintained by an
        // INSERT trigger — it survives wipes with zero changes to sync code.
        // Existing tracks get their first_seen at the first post-migration
        // (re)sync — a one-time "everything added today" artifact; genuinely
        // new albums bubble to the top from then on.
        migrator.registerMigration("v30_track_first_seen") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS track_first_seen (
                    match_key  TEXT PRIMARY KEY,
                    first_seen TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS trg_tracks_first_seen
                AFTER INSERT ON tracks
                WHEN NEW.match_key IS NOT NULL
                BEGIN
                    INSERT OR IGNORE INTO track_first_seen (match_key, first_seen)
                    VALUES (NEW.match_key, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
                END
                """)
        }

        // Cached artist biographies (Last.fm artist.getinfo) for the artist
        // page — keyed by lowercased artist name, refreshed after 30 days.
        migrator.registerMigration("v31_artist_bio") { db in
            try db.create(table: "artist_bio", ifNotExists: true) { t in
                t.primaryKey("artist_key", .text)
                t.column("bio",        .text)            // nil = negative cache (no bio found)
                t.column("fetched_at", .text).notNull()
            }
        }

        // Starred albums/artists (LMS-style favorites), server-of-record like
        // track_feedback. `key` is content-derived (artist: lowercased name;
        // album: "album|artist" lowercased) so it survives resyncs.
        migrator.registerMigration("v32_favorites") { db in
            try db.create(table: "favorites", ifNotExists: true) { t in
                t.column("kind",       .text).notNull()   // "artist" | "album"
                t.column("key",        .text).notNull()
                t.column("title",      .text)             // display: album/artist name
                t.column("artist",     .text)             // album favorites: the artist
                t.column("created_at", .text).notNull()
                t.primaryKey(["kind", "key"])
            }
        }

        // "Bewaar voor later" (muffon-style bookmarks) — a lightweight
        // listen-later list, distinct from favorites (love it) and feedback
        // (like/dislike). Spans tracks/albums/artists; content-derived `key`
        // survives resyncs (track: "title|artist"; album: "album|artist";
        // artist: name — all lowercased). Server-of-record like favorites.
        migrator.registerMigration("v33_bookmarks") { db in
            try db.create(table: "bookmarks", ifNotExists: true) { t in
                t.column("kind",       .text).notNull()   // "track" | "album" | "artist"
                t.column("key",        .text).notNull()
                t.column("title",      .text)             // display: track/album/artist name
                t.column("artist",     .text)             // track/album: the artist
                t.column("album",      .text)             // track: the album (re-resolve hint)
                t.column("created_at", .text).notNull()
                t.primaryKey(["kind", "key"])
            }
        }

        // Global "listeners of X also play Y" signal (Deezer related artists) —
        // the collaborative-filtering leg the content-based radios lacked. Keyed
        // by lowercased seed-artist name; a sentinel row (related = '') marks a
        // negative lookup so the fetcher doesn't retry a Deezer-unknown artist
        // every build. Refreshed after ~30 days. Server-of-record fetches;
        // clients don't need it (radios build on the server).
        migrator.registerMigration("v34_related_artists") { db in
            try db.create(table: "related_artists", ifNotExists: true) { t in
                t.column("artist_key", .text).notNull()   // lowercased seed artist
                t.column("related",    .text).notNull()   // lowercased related name ('' = negative cache)
                t.column("rank",       .integer).notNull().defaults(to: 0)
                t.column("fetched_at", .text).notNull()
                t.primaryKey(["artist_key", "related"])
            }
        }

        // Implicit negative feedback: how often a track was SKIPPED early (played
        // < ~25s then replaced). A single skip is noise; a track skipped several
        // times is a real "not for me" the radios should heed — folded into the
        // radio dislike down-sampling at a threshold, WITHOUT surfacing as an
        // explicit thumbs-down in the feedback UI. Keyed by content match_key so
        // it survives a Roon resync (the track_feedback pattern).
        migrator.registerMigration("v35_track_skips") { db in
            try db.create(table: "track_skips", ifNotExists: true) { t in
                t.primaryKey("match_key", .text)
                t.column("skip_count",   .integer).notNull().defaults(to: 0)
                t.column("last_skipped", .text).notNull()
            }
        }

        // User-composed sonic radios (RadioConfig) — a named bundle of seed facets
        // (artists/tracks/genres/moods/activities/decades) the user assembles, edits
        // and toggles. Server-of-record like playlists/favorites so every client
        // shows the same set; the analyzer materialises the enabled ones to Qobuz.
        // Facet lists are JSON-text columns (GRDB stores arrays as JSON).
        migrator.registerMigration("v36_radio_configs") { db in
            try db.create(table: "radio_configs", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("name",            .text).notNull()
                t.column("enabled",         .boolean).notNull().defaults(to: true)
                t.column("sync_to_qobuz",   .boolean).notNull().defaults(to: true)
                t.column("artists",         .text).notNull().defaults(to: "[]")
                t.column("track_keys",      .text).notNull().defaults(to: "[]")
                t.column("genres",          .text).notNull().defaults(to: "[]")
                t.column("moods",           .text).notNull().defaults(to: "[]")
                t.column("activities",      .text).notNull().defaults(to: "[]")
                t.column("decades",         .text).notNull().defaults(to: "[]")
                t.column("adventurousness", .double).notNull().defaults(to: 0.35)
                t.column("target_count",    .integer).notNull().defaults(to: 25)
                t.column("qobuz_playlist_id", .text)
                t.column("updated_at",      .text).notNull()
            }
        }

        // Hard cross-source identity from the offline MusicMoveArr dataset import
        // (analyzer `import-dataset`), synced via /features. `isrc` joins the
        // library to Qobuz/Deezer/Tidal catalogs without string matching;
        // `recording_mbid` is the canonical MusicBrainz recording. NULL until the
        // analyzer's sidecar import matches a track.
        migrator.registerMigration("v37_track_identity") { db in
            try db.execute(sql: "ALTER TABLE track_audio_features ADD COLUMN isrc TEXT")
            try db.execute(sql: "ALTER TABLE track_audio_features ADD COLUMN recording_mbid TEXT")
        }

        // Deezer dump's TrackBPM — a SECONDARY tempo reference (not the source of
        // truth). Used only to octave-correct a low-confidence native BPM in the
        // DJ candidate path (TempoReconciler); never introduces tracks. NULL until
        // the dataset import matches a track.
        migrator.registerMigration("v38_track_deezer_bpm") { db in
            try db.execute(sql: "ALTER TABLE track_audio_features ADD COLUMN deezer_bpm REAL")
        }

        try migrator.migrate(db)
    }
}
