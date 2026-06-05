"""Database schema creation for RoonSage."""

import sqlite3


def _create_schema_tables(conn: sqlite3.Connection) -> None:
    """Create all tables and indexes using the latest schema.

    This is always called at startup (CREATE TABLE IF NOT EXISTS is idempotent).
    Column definitions already include every column that was added via
    ALTER TABLE migrations, so fresh databases need no migrations at all.
    Old databases still get missing columns through the numbered migrations.
    """
    conn.executescript("""
        -- ----------------------------------------------------------------
        -- Core library cache
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS tracks (
            item_key        TEXT PRIMARY KEY,
            title           TEXT NOT NULL,
            artist          TEXT NOT NULL,
            album           TEXT NOT NULL,
            duration_ms     INTEGER,
            year            INTEGER,
            genres          TEXT,
            is_live         BOOLEAN,
            parent_item_key TEXT,
            updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            track_index     INTEGER,
            view_count      INTEGER DEFAULT 0,
            last_viewed_at  TEXT,
            image_key       TEXT,
            stable_id       TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_tracks_artist            ON tracks(artist);
        CREATE INDEX IF NOT EXISTS idx_tracks_year              ON tracks(year);
        CREATE INDEX IF NOT EXISTS idx_tracks_is_live           ON tracks(is_live);
        CREATE INDEX IF NOT EXISTS idx_tracks_artist_lower      ON tracks(LOWER(artist));
        CREATE INDEX IF NOT EXISTS idx_tracks_title_lower       ON tracks(LOWER(title));
        CREATE INDEX IF NOT EXISTS idx_tracks_title_artist_lower ON tracks(LOWER(title), LOWER(artist));
        CREATE INDEX IF NOT EXISTS idx_tracks_parent_key        ON tracks(parent_item_key);
        CREATE INDEX IF NOT EXISTS idx_tracks_stable_id         ON tracks(stable_id);

        -- Sync state: single-row metadata table
        CREATE TABLE IF NOT EXISTS sync_state (
            id              INTEGER PRIMARY KEY CHECK (id = 1),
            roon_core_id    TEXT,
            last_sync_at    TIMESTAMP,
            track_count     INTEGER DEFAULT 0,
            sync_duration_ms INTEGER
        );
        INSERT OR IGNORE INTO sync_state (id) VALUES (1);

        CREATE TABLE IF NOT EXISTS albums (
            item_key   TEXT PRIMARY KEY,
            title      TEXT NOT NULL,
            artist     TEXT NOT NULL,
            year       INTEGER,
            genres     TEXT,
            image_key  TEXT,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS idx_albums_artist       ON albums(artist);
        CREATE INDEX IF NOT EXISTS idx_albums_artist_lower ON albums(LOWER(artist));

        -- Genre junction table
        CREATE TABLE IF NOT EXISTS track_genres (
            track_key TEXT NOT NULL,
            genre     TEXT NOT NULL,
            stable_id TEXT,
            PRIMARY KEY (track_key, genre),
            FOREIGN KEY (track_key) REFERENCES tracks(item_key)
        );
        CREATE INDEX IF NOT EXISTS idx_track_genres_genre     ON track_genres(genre);
        CREATE INDEX IF NOT EXISTS idx_track_genres_track_key ON track_genres(track_key, genre);
        CREATE INDEX IF NOT EXISTS idx_track_genres_stable_id ON track_genres(stable_id);

        CREATE TABLE IF NOT EXISTS results (
            id             TEXT PRIMARY KEY,
            type           TEXT NOT NULL,
            title          TEXT NOT NULL,
            prompt         TEXT NOT NULL,
            snapshot       JSON NOT NULL,
            track_count    INTEGER NOT NULL,
            artist         TEXT,
            art_item_key   TEXT,
            created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            subtitle       TEXT,
            source_mode    TEXT,
            ai_description TEXT,
            ai_tags        TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_results_type_created ON results(type, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_results_created_at   ON results(created_at DESC);

        -- ----------------------------------------------------------------
        -- Intelligence layer
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS taste_profile (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            profile_json TEXT NOT NULL DEFAULT '{}'
        );
        INSERT OR IGNORE INTO taste_profile (id, profile_json) VALUES (1, '{}');

        CREATE TABLE IF NOT EXISTS taste_events (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp  TEXT NOT NULL DEFAULT (datetime('now')),
            event_type TEXT NOT NULL,
            data_json  TEXT NOT NULL DEFAULT '{}'
        );
        CREATE INDEX IF NOT EXISTS idx_taste_events_ts ON taste_events(timestamp DESC);

        CREATE TABLE IF NOT EXISTS listening_history (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp       TEXT NOT NULL DEFAULT (datetime('now')),
            zone_name       TEXT,
            track_title     TEXT,
            artist          TEXT,
            album           TEXT,
            genre           TEXT,
            duration_seconds INTEGER,
            played_seconds  INTEGER,
            skipped         INTEGER DEFAULT 0,
            year            INTEGER,
            decade          TEXT,
            hour_of_day     INTEGER,
            day_of_week     INTEGER,
            source          TEXT DEFAULT 'library',
            played_pct      REAL
        );
        CREATE INDEX IF NOT EXISTS idx_listening_ts           ON listening_history(timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_listening_artist       ON listening_history(artist);
        CREATE INDEX IF NOT EXISTS idx_listening_artist_lower ON listening_history(LOWER(artist));
        CREATE INDEX IF NOT EXISTS idx_listening_title_lower  ON listening_history(LOWER(track_title));

        CREATE TABLE IF NOT EXISTS saved_playlists (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            name            TEXT NOT NULL,
            prompt          TEXT,
            created_at      TEXT NOT NULL DEFAULT (datetime('now')),
            source_mode     TEXT DEFAULT 'library',
            track_count     INTEGER DEFAULT 0,
            tracks_json     TEXT,
            tags            TEXT DEFAULT '',
            qobuz_playlist_id TEXT,
            rating          INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_saved_playlists_created ON saved_playlists(created_at DESC);

        CREATE TABLE IF NOT EXISTS similar_artists (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            artist_name TEXT NOT NULL,
            similar_to  TEXT NOT NULL,
            score       REAL DEFAULT 0.5,
            source      TEXT DEFAULT 'musicbrainz',
            UNIQUE(artist_name, similar_to)
        );

        -- ----------------------------------------------------------------
        -- ListenBrainz / Last.fm caches
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS lb_stats_cache (
            stat_type  TEXT PRIMARY KEY,
            data_json  TEXT NOT NULL DEFAULT '{}',
            range      TEXT DEFAULT 'all_time',
            synced_at  TEXT NOT NULL DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS lastfm_stats_cache (
            stat_type  TEXT PRIMARY KEY,
            data_json  TEXT NOT NULL DEFAULT '{}',
            synced_at  TEXT NOT NULL DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS scrobble_import_state (
            source           TEXT PRIMARY KEY,
            status           TEXT DEFAULT 'idle',
            total_imported   INTEGER DEFAULT 0,
            last_ts          INTEGER,
            started_at       TEXT,
            completed_at     TEXT,
            error_message    TEXT
        );

        CREATE UNIQUE INDEX IF NOT EXISTS idx_listening_external_dedup
            ON listening_history(source, timestamp)
            WHERE source IN ('lastfm', 'listenbrainz');

        -- ----------------------------------------------------------------
        -- Notifications
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS notification_log (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp     TEXT NOT NULL DEFAULT (datetime('now')),
            event_type    TEXT NOT NULL,
            channel       TEXT NOT NULL,
            success       INTEGER NOT NULL DEFAULT 1,
            error_message TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_notification_log_ts ON notification_log(timestamp DESC);

        -- ----------------------------------------------------------------
        -- Artist Watchlist
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS artist_watchlist (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            artist_name      TEXT NOT NULL UNIQUE,
            added_at         TEXT NOT NULL DEFAULT (datetime('now')),
            auto_added       INTEGER DEFAULT 0,
            monitor_albums   INTEGER DEFAULT 1,
            monitor_eps      INTEGER DEFAULT 1,
            monitor_singles  INTEGER DEFAULT 0,
            last_checked     TEXT,
            last_new_release TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_watchlist_artist ON artist_watchlist(artist_name);

        CREATE TABLE IF NOT EXISTS artist_releases_cache (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            artist_name  TEXT NOT NULL,
            album_title  TEXT NOT NULL,
            release_date TEXT,
            release_type TEXT,
            qobuz_id     TEXT,
            item_key     TEXT,
            first_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
            notified     INTEGER DEFAULT 0,
            UNIQUE(artist_name, album_title)
        );
        CREATE INDEX IF NOT EXISTS idx_releases_artist   ON artist_releases_cache(artist_name);
        CREATE INDEX IF NOT EXISTS idx_releases_notified ON artist_releases_cache(notified);

        -- ----------------------------------------------------------------
        -- Scheduled Playlists
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS scheduled_playlists (
            id                INTEGER PRIMARY KEY AUTOINCREMENT,
            name              TEXT NOT NULL,
            prompt            TEXT NOT NULL,
            filters           TEXT,
            track_count       INTEGER DEFAULT 25,
            schedule          TEXT NOT NULL,
            zone_name         TEXT,
            save_to_qobuz     INTEGER DEFAULT 1,
            qobuz_playlist_id TEXT,
            enabled           INTEGER DEFAULT 1,
            last_run          TEXT,
            last_status       TEXT,
            last_error        TEXT,
            created_at        TEXT NOT NULL DEFAULT (datetime('now')),
            schedule_type     TEXT DEFAULT 'prompt'
        );
        CREATE INDEX IF NOT EXISTS idx_scheduled_playlists_enabled ON scheduled_playlists(enabled);

        -- ----------------------------------------------------------------
        -- Automation Engine
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS automations (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            name            TEXT NOT NULL,
            trigger_type    TEXT NOT NULL,
            trigger_config  TEXT NOT NULL DEFAULT '{}',
            action_type     TEXT NOT NULL,
            action_config   TEXT NOT NULL DEFAULT '{}',
            then_actions    TEXT NOT NULL DEFAULT '[]',
            enabled         INTEGER DEFAULT 1,
            last_triggered  TEXT,
            last_status     TEXT,
            run_count       INTEGER DEFAULT 0,
            cooldown_seconds INTEGER DEFAULT 300,
            created_at      TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_automations_enabled ON automations(enabled);
        CREATE INDEX IF NOT EXISTS idx_automations_trigger ON automations(trigger_type);

        CREATE TABLE IF NOT EXISTS automation_log (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            automation_id INTEGER,
            triggered_at  TEXT NOT NULL DEFAULT (datetime('now')),
            trigger_type  TEXT,
            action_type   TEXT,
            status        TEXT,
            duration_ms   INTEGER,
            error_message TEXT,
            FOREIGN KEY(automation_id) REFERENCES automations(id)
        );
        CREATE INDEX IF NOT EXISTS idx_automation_log_ts        ON automation_log(triggered_at DESC);
        CREATE INDEX IF NOT EXISTS idx_automation_log_automation ON automation_log(automation_id);

        -- ----------------------------------------------------------------
        -- Metadata Enrichment Pipeline
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS track_metadata_ext (
            item_key            TEXT PRIMARY KEY,
            musicbrainz_id      TEXT,
            mb_tags             TEXT,
            mb_release_date     TEXT,
            mb_country          TEXT,
            lastfm_tags         TEXT,
            lastfm_listeners    INTEGER,
            lastfm_playcount    INTEGER,
            enriched_at         TEXT NOT NULL DEFAULT (datetime('now')),
            enrichment_source   TEXT,
            stable_id           TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_track_metadata_ext_key      ON track_metadata_ext(item_key);
        CREATE INDEX IF NOT EXISTS idx_track_metadata_ext_stable_id ON track_metadata_ext(stable_id);

        CREATE TABLE IF NOT EXISTS enrichment_queue (
            item_key      TEXT PRIMARY KEY,
            artist        TEXT NOT NULL,
            title         TEXT NOT NULL,
            album         TEXT,
            status        TEXT DEFAULT 'pending',
            error_message TEXT,
            attempts      INTEGER DEFAULT 0,
            created_at    TEXT DEFAULT (datetime('now')),
            processed_at  TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_enrichment_queue_status ON enrichment_queue(status);

        -- ----------------------------------------------------------------
        -- Audio Feature Analysis
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS track_audio_features (
            item_key          TEXT PRIMARY KEY,
            file_path         TEXT,
            bpm               REAL,
            bpm_confidence    REAL,
            key_root          TEXT,
            key_mode          TEXT,
            camelot           TEXT,
            energy            REAL,
            danceability      REAL,
            valence           REAL,
            acousticness      REAL,
            instrumentalness  REAL,
            loudness_lufs     REAL,
            analyzed_at       TEXT NOT NULL DEFAULT (datetime('now')),
            analysis_version  INTEGER DEFAULT 1,
            error_message     TEXT,
            cluster_id        INTEGER,
            x_2d              REAL,
            y_2d              REAL,
            stable_id         TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_audio_features_bpm        ON track_audio_features(bpm);
        CREATE INDEX IF NOT EXISTS idx_audio_features_camelot    ON track_audio_features(camelot);
        CREATE INDEX IF NOT EXISTS idx_audio_features_energy     ON track_audio_features(energy);
        CREATE INDEX IF NOT EXISTS idx_audio_features_valence    ON track_audio_features(valence);
        CREATE INDEX IF NOT EXISTS idx_audio_features_bpm_valence ON track_audio_features(bpm, valence);
        CREATE INDEX IF NOT EXISTS idx_audio_features_cluster    ON track_audio_features(cluster_id);
        CREATE INDEX IF NOT EXISTS idx_audio_features_stable_id  ON track_audio_features(stable_id);

        CREATE TABLE IF NOT EXISTS audio_features_queue (
            item_key      TEXT PRIMARY KEY,
            file_path     TEXT,
            status        TEXT DEFAULT 'pending',
            attempts      INTEGER DEFAULT 0,
            error_message TEXT,
            created_at    TEXT DEFAULT (datetime('now')),
            processed_at  TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_audio_features_queue_status ON audio_features_queue(status);

        CREATE TABLE IF NOT EXISTS cluster_runs (
            id          INTEGER PRIMARY KEY CHECK (id = 1),
            started_at  TEXT,
            finished_at TEXT,
            status      TEXT DEFAULT 'idle',
            n_tracks    INTEGER DEFAULT 0,
            n_clusters  INTEGER DEFAULT 0,
            n_noise     INTEGER DEFAULT 0,
            params_json TEXT DEFAULT '{}',
            error_message TEXT
        );
        INSERT OR IGNORE INTO cluster_runs (id, status) VALUES (1, 'idle');

        CREATE TABLE IF NOT EXISTS dj_sets (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            name             TEXT NOT NULL,
            created_at       TEXT NOT NULL DEFAULT (datetime('now')),
            duration_minutes INTEGER NOT NULL DEFAULT 0,
            track_count      INTEGER NOT NULL DEFAULT 0,
            start_bpm        REAL,
            end_bpm          REAL,
            start_mood       TEXT,
            end_mood         TEXT,
            genres_json      TEXT NOT NULL DEFAULT '[]',
            tracks_json      TEXT NOT NULL DEFAULT '[]',
            curve_json       TEXT NOT NULL DEFAULT '[]'
        );
        CREATE INDEX IF NOT EXISTS idx_dj_sets_created ON dj_sets(created_at DESC);

        -- ----------------------------------------------------------------
        -- CLAP text-to-audio embeddings
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS clap_embeddings (
            item_key    TEXT PRIMARY KEY,
            embedding   BLOB NOT NULL,
            model       TEXT,
            analyzed_at TEXT NOT NULL DEFAULT (datetime('now')),
            stable_id   TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_clap_embeddings_analyzed  ON clap_embeddings(analyzed_at DESC);
        CREATE INDEX IF NOT EXISTS idx_clap_embeddings_stable_id ON clap_embeddings(stable_id);

        CREATE TABLE IF NOT EXISTS clap_runs (
            id          INTEGER PRIMARY KEY CHECK (id = 1),
            status      TEXT DEFAULT 'idle',
            started_at  TEXT,
            finished_at TEXT,
            n_total     INTEGER DEFAULT 0,
            n_done      INTEGER DEFAULT 0,
            n_failed    INTEGER DEFAULT 0,
            error_message TEXT
        );
        INSERT OR IGNORE INTO clap_runs (id, status) VALUES (1, 'idle');

        -- ----------------------------------------------------------------
        -- Mood tagging
        -- track_mood_tags intentionally has NO FK to tracks (full-replace
        -- resync does DELETE FROM tracks, which would cascade-delete mood rows).
        -- Mood rows survive via stable_id instead.
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS track_mood_tags (
            track_id       TEXT PRIMARY KEY,
            mood_primary   TEXT NOT NULL,
            mood_secondary TEXT,
            confidence     REAL,
            cluster_id     INTEGER,
            updated_at     TEXT NOT NULL DEFAULT (datetime('now')),
            stable_id      TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_track_mood_primary    ON track_mood_tags(mood_primary);
        CREATE INDEX IF NOT EXISTS idx_track_mood_secondary  ON track_mood_tags(mood_secondary);
        CREATE INDEX IF NOT EXISTS idx_track_mood_tags_stable_id ON track_mood_tags(stable_id);

        CREATE TABLE IF NOT EXISTS mood_runs (
            id          INTEGER PRIMARY KEY CHECK (id = 1),
            status      TEXT DEFAULT 'idle',
            started_at  TEXT,
            finished_at TEXT,
            n_tracks    INTEGER DEFAULT 0,
            n_clusters  INTEGER DEFAULT 0,
            error_message TEXT
        );
        INSERT OR IGNORE INTO mood_runs (id, status) VALUES (1, 'idle');

        -- ----------------------------------------------------------------
        -- Lyrics extraction + semantic embeddings
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS lyrics_data (
            item_key     TEXT PRIMARY KEY,
            lyrics       TEXT,
            language     TEXT,
            source       TEXT,
            extracted_at TEXT NOT NULL DEFAULT (datetime('now')),
            stable_id    TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_lyrics_data_lang      ON lyrics_data(language);
        CREATE INDEX IF NOT EXISTS idx_lyrics_data_stable_id ON lyrics_data(stable_id);

        CREATE TABLE IF NOT EXISTS lyrics_embeddings (
            item_key      TEXT PRIMARY KEY,
            embedding     BLOB NOT NULL,
            model_version TEXT,
            embedded_at   TEXT NOT NULL DEFAULT (datetime('now')),
            stable_id     TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_lyrics_embeddings_stable_id ON lyrics_embeddings(stable_id);

        CREATE TABLE IF NOT EXISTS lyrics_runs (
            id           INTEGER PRIMARY KEY CHECK (id = 1),
            status       TEXT DEFAULT 'idle',
            started_at   TEXT,
            finished_at  TEXT,
            n_total      INTEGER DEFAULT 0,
            n_extracted  INTEGER DEFAULT 0,
            n_embedded   INTEGER DEFAULT 0,
            n_no_lyrics  INTEGER DEFAULT 0,
            n_failed     INTEGER DEFAULT 0,
            error_message TEXT
        );
        INSERT OR IGNORE INTO lyrics_runs (id, status) VALUES (1, 'idle');

        -- ----------------------------------------------------------------
        -- Cluster labels
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS cluster_labels (
            cluster_id       INTEGER PRIMARY KEY,
            label_primary    TEXT,
            label_secondary  TEXT,
            label_tertiary   TEXT,
            track_count      INTEGER DEFAULT 0,
            source           TEXT,
            updated_at       TEXT NOT NULL DEFAULT (datetime('now'))
        );

        -- ----------------------------------------------------------------
        -- Song Alchemy profiles
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS alchemy_profiles (
            id                 INTEGER PRIMARY KEY AUTOINCREMENT,
            name               TEXT NOT NULL UNIQUE,
            zone_id            TEXT,
            add_features       TEXT NOT NULL,
            subtract_features  TEXT,
            add_track_ids      TEXT,
            subtract_track_ids TEXT,
            created_at         TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at         TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_alchemy_profiles_zone ON alchemy_profiles(zone_id);

        -- ----------------------------------------------------------------
        -- LLM response cache
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS llm_response_cache (
            cache_key     TEXT PRIMARY KEY,
            kind          TEXT NOT NULL,
            content       TEXT NOT NULL,
            model         TEXT NOT NULL,
            input_tokens  INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0,
            created_at    INTEGER NOT NULL,
            hit_count     INTEGER DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_llm_response_cache_created ON llm_response_cache(created_at);
        CREATE INDEX IF NOT EXISTS idx_llm_response_cache_kind    ON llm_response_cache(kind);

        -- ----------------------------------------------------------------
        -- Background AI enrichment
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS track_vibes (
            item_key   TEXT PRIMARY KEY,
            contexts   TEXT NOT NULL DEFAULT '[]',
            moods      TEXT NOT NULL DEFAULT '[]',
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS weekly_insights_cache (
            id           INTEGER PRIMARY KEY CHECK (id = 1),
            insights     TEXT NOT NULL DEFAULT '[]',
            headline     TEXT NOT NULL DEFAULT '',
            generated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS discovery_descriptions (
            section_type TEXT PRIMARY KEY,
            tagline      TEXT NOT NULL DEFAULT '',
            description  TEXT NOT NULL DEFAULT '',
            generated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS track_lyrics_themes (
            item_key       TEXT PRIMARY KEY,
            themes         TEXT NOT NULL DEFAULT '[]',
            emotional_arc  TEXT NOT NULL DEFAULT '',
            language       TEXT NOT NULL DEFAULT '',
            abstract_level TEXT NOT NULL DEFAULT '',
            updated_at     TEXT NOT NULL DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS cluster_ai_labels (
            cluster_id   INTEGER PRIMARY KEY,
            label        TEXT NOT NULL DEFAULT '',
            description  TEXT NOT NULL DEFAULT '',
            color_hint   TEXT NOT NULL DEFAULT '',
            generated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS song_path_narratives (
            cache_key      TEXT PRIMARY KEY,
            narrative      TEXT NOT NULL DEFAULT '',
            arc_type       TEXT NOT NULL DEFAULT '',
            key_transition TEXT NOT NULL DEFAULT '',
            generated_at   TEXT NOT NULL DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS template_suggestions_cache (
            id           INTEGER PRIMARY KEY CHECK (id = 1),
            suggestions  TEXT NOT NULL DEFAULT '[]',
            generated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );

        -- ----------------------------------------------------------------
        -- Circadian auto-playlists (v13.6)
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS circadian_playlists (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            date          TEXT NOT NULL,
            time_block    TEXT NOT NULL,
            prompt_used   TEXT NOT NULL DEFAULT '',
            result_id     TEXT,
            queued_to_zone TEXT,
            created_at    TEXT NOT NULL DEFAULT (datetime('now')),
            UNIQUE(date, time_block)
        );
        CREATE INDEX IF NOT EXISTS idx_circadian_playlists_date ON circadian_playlists(date DESC);

        -- ----------------------------------------------------------------
        -- Listening sessions (v13.6)
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS listening_sessions (
            id                     INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at             TEXT NOT NULL,
            ended_at               TEXT NOT NULL,
            zone_name              TEXT,
            track_count            INTEGER NOT NULL DEFAULT 0,
            total_duration_minutes REAL NOT NULL DEFAULT 0,
            genres_json            TEXT NOT NULL DEFAULT '[]',
            summary_text           TEXT NOT NULL DEFAULT '',
            mood_arc               TEXT NOT NULL DEFAULT '',
            standout_tracks_json   TEXT NOT NULL DEFAULT '[]',
            energy_curve_json      TEXT NOT NULL DEFAULT '[]',
            summarized             INTEGER NOT NULL DEFAULT 0,
            created_at             TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_listening_sessions_ended      ON listening_sessions(ended_at DESC);
        CREATE INDEX IF NOT EXISTS idx_listening_sessions_summarized ON listening_sessions(summarized, ended_at);

        -- ----------------------------------------------------------------
        -- Queue continuation cooldown ledger
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS queue_continuation_log (
            zone_id          TEXT PRIMARY KEY,
            zone_name        TEXT,
            last_fired_at    TEXT NOT NULL,
            last_result_id   TEXT,
            last_track_count INTEGER NOT NULL DEFAULT 0,
            last_status      TEXT NOT NULL DEFAULT 'ok',
            last_error       TEXT
        );

        -- ----------------------------------------------------------------
        -- Schema version tracking (added at end to avoid executescript commit
        -- ordering issues with INSERT OR IGNORE on other tables)
        -- ----------------------------------------------------------------

        CREATE TABLE IF NOT EXISTS schema_version (
            id      INTEGER PRIMARY KEY CHECK (id = 1),
            version INTEGER NOT NULL DEFAULT 0
        );
        INSERT OR IGNORE INTO schema_version (id, version) VALUES (1, 0);
    """)
