"""Database connection and schema management for RoonSage.

Provides get_db_connection(), init_schema(), ensure_db_initialized(),
needs_resync(), get_connection() (sync context manager), aget_connection()
(async context manager via aiosqlite), and execute_write().
"""

import asyncio  # noqa: F401 — kept for callers that import it from here
import contextlib
import logging
import os
import sqlite3
import threading
from collections.abc import Callable, Generator
from contextlib import asynccontextmanager, contextmanager
from pathlib import Path

import aiosqlite

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# The SQLite DB lives in ROONSAGE_DB_DIR when set, otherwise alongside the rest
# of the data dir. On macOS + Docker Desktop, keep this on a *named volume*
# (inside the Linux VM) rather than a bind mount: SQLite WAL over the macOS
# file-sharing layer corrupts the database under heavy writes.
DATA_DIR = Path(os.environ.get("ROONSAGE_DB_DIR") or (Path(__file__).parent.parent / "data"))
DB_PATH = DATA_DIR / "library_cache.db"

# ---------------------------------------------------------------------------
# Module-level schema state
# ---------------------------------------------------------------------------

_schema_initialized = False
_schema_lock = threading.Lock()

# True when init_schema() applied at least one ALTER TABLE migration that
# touches the tracks table structure (signals need for re-sync).
# Cleared by clear_migration_flag() after a successful library sync.
_migration_applied = False


# ---------------------------------------------------------------------------
# Connection helpers
# ---------------------------------------------------------------------------


def get_db_connection() -> sqlite3.Connection:
    """Open a WAL-mode SQLite connection with dict-like row access."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(str(DB_PATH), timeout=30.0)
    conn.row_factory = sqlite3.Row

    # WAL mode: concurrent readers during writes.
    # After a crash or force-kill the -shm (WAL index) can be left in an
    # inconsistent state, causing "database disk image is malformed" on the
    # first PRAGMA journal_mode=WAL of a new connection.
    # Recovery: switch to DELETE journal mode first (doesn't use SHM), which
    # checkpoints and removes the WAL/SHM files, then reopen in WAL mode.
    # As last resort, delete the stale SHM/WAL files directly.
    try:
        conn.execute("PRAGMA journal_mode=WAL")
    except sqlite3.DatabaseError:
        logger.warning("WAL header inconsistent; attempting journal reset recovery")
        try:
            conn.execute("PRAGMA journal_mode=DELETE")
        except Exception as exc:
            logger.warning("journal_mode=DELETE failed: %s", exc)
        conn.close()
        shm_path = DB_PATH.parent / (DB_PATH.name + "-shm")
        wal_path = DB_PATH.parent / (DB_PATH.name + "-wal")
        for p in (shm_path, wal_path):
            if p.exists():
                try:
                    p.unlink()
                    logger.info("Removed stale WAL artefact: %s", p.name)
                except OSError as exc:
                    logger.warning("Could not remove %s: %s", p.name, exc)
        conn = sqlite3.connect(str(DB_PATH), timeout=30.0)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")

    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA foreign_keys=ON")

    return conn


# ---------------------------------------------------------------------------
# Schema management
# ---------------------------------------------------------------------------

# Increment whenever a new migration is added at the bottom of _MIGRATIONS.
SCHEMA_VERSION = 18


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


# ---------------------------------------------------------------------------
# Individual migration functions
# Each returns True if it actually changed something, False if it was a no-op.
# ---------------------------------------------------------------------------

def _m01_rename_rating_key(conn: sqlite3.Connection) -> bool:
    try:
        conn.execute("ALTER TABLE tracks RENAME COLUMN rating_key TO item_key")
        logger.info("Migration 1: renamed rating_key → item_key in tracks")
        return True
    except sqlite3.OperationalError:
        return False


def _m02_rename_parent_rating_key(conn: sqlite3.Connection) -> bool:
    try:
        conn.execute("ALTER TABLE tracks RENAME COLUMN parent_rating_key TO parent_item_key")
        logger.info("Migration 2: renamed parent_rating_key → parent_item_key in tracks")
        return True
    except sqlite3.OperationalError:
        return False


def _m03_rename_art_rating_key(conn: sqlite3.Connection) -> bool:
    try:
        conn.execute("ALTER TABLE results RENAME COLUMN art_rating_key TO art_item_key")
        logger.info("Migration 3: renamed art_rating_key → art_item_key in results")
    except sqlite3.OperationalError:
        pass
    return False  # results rename never required a library resync


def _m04_add_parent_item_key(conn: sqlite3.Connection) -> bool:
    try:
        conn.execute("ALTER TABLE tracks ADD COLUMN parent_item_key TEXT")
        logger.info("Migration 4: added parent_item_key to tracks")
        return True
    except sqlite3.OperationalError:
        return False


def _m05_add_track_index(conn: sqlite3.Connection) -> bool:
    try:
        conn.execute("ALTER TABLE tracks ADD COLUMN track_index INTEGER")
        logger.info("Migration 5: added track_index to tracks")
        return True
    except sqlite3.OperationalError:
        return False


def _m06_add_view_count(conn: sqlite3.Connection) -> bool:
    try:
        conn.execute("ALTER TABLE tracks ADD COLUMN view_count INTEGER DEFAULT 0")
        logger.info("Migration 6: added view_count to tracks")
        return True
    except sqlite3.OperationalError:
        return False


def _m07_add_last_viewed_at(conn: sqlite3.Connection) -> bool:
    try:
        conn.execute("ALTER TABLE tracks ADD COLUMN last_viewed_at TEXT")
        logger.info("Migration 7: added last_viewed_at to tracks")
        return True
    except sqlite3.OperationalError:
        return False


def _m08_add_image_key_tracks(conn: sqlite3.Connection) -> bool:
    try:
        conn.execute("ALTER TABLE tracks ADD COLUMN image_key TEXT")
        logger.info("Migration 8: added image_key to tracks")
    except sqlite3.OperationalError:
        pass
    return False


def _m09_add_results_subtitle_source_mode(conn: sqlite3.Connection) -> bool:
    for col, ctype in [("subtitle", "TEXT"), ("source_mode", "TEXT")]:
        try:
            conn.execute(f"ALTER TABLE results ADD COLUMN {col} {ctype}")
            logger.info("Migration 9: added %s to results", col)
        except sqlite3.OperationalError:
            pass
    return False


def _m10_rename_plex_server_id(conn: sqlite3.Connection) -> bool:
    try:
        conn.execute("ALTER TABLE sync_state RENAME COLUMN plex_server_id TO roon_core_id")
        logger.info("Migration 10: renamed plex_server_id → roon_core_id in sync_state")
    except sqlite3.OperationalError:
        pass
    return False


def _m11_lb_columns(conn: sqlite3.Connection) -> bool:
    for col, ctype in [
        ("year", "INTEGER"),
        ("decade", "TEXT"),
        ("hour_of_day", "INTEGER"),
        ("day_of_week", "INTEGER"),
        ("source", "TEXT DEFAULT 'library'"),
        ("played_pct", "REAL"),
    ]:
        try:
            conn.execute(f"ALTER TABLE listening_history ADD COLUMN {col} {ctype}")
            logger.info("Migration 11: added %s to listening_history", col)
        except sqlite3.OperationalError:
            pass
    return False


def _m12_mood_tags_cluster_id(conn: sqlite3.Connection) -> bool:
    try:
        conn.execute("ALTER TABLE track_mood_tags ADD COLUMN cluster_id INTEGER")
        logger.info("Migration 12: added cluster_id to track_mood_tags")
    except sqlite3.OperationalError:
        pass
    return False


def _m13_audio_features_cluster_columns(conn: sqlite3.Connection) -> bool:
    for col, ctype in [("cluster_id", "INTEGER"), ("x_2d", "REAL"), ("y_2d", "REAL")]:
        try:
            conn.execute(f"ALTER TABLE track_audio_features ADD COLUMN {col} {ctype}")
            logger.info("Migration 13: added %s to track_audio_features", col)
        except sqlite3.OperationalError:
            pass
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_audio_features_cluster "
        "ON track_audio_features(cluster_id)"
    )
    return False


def _m14_scheduled_playlists_schedule_type(conn: sqlite3.Connection) -> bool:
    try:
        conn.execute(
            "ALTER TABLE scheduled_playlists ADD COLUMN schedule_type TEXT DEFAULT 'prompt'"
        )
        logger.info("Migration 14: added schedule_type to scheduled_playlists")
    except sqlite3.OperationalError:
        pass
    return False


def _m15_results_ai_columns(conn: sqlite3.Connection) -> bool:
    for col in ("ai_description", "ai_tags"):
        with contextlib.suppress(sqlite3.OperationalError):
            conn.execute(f"ALTER TABLE results ADD COLUMN {col} TEXT")
            logger.info("Migration 15: added %s to results", col)
    return False


def _m16_stable_id_columns(conn: sqlite3.Connection) -> bool:
    _ensure_stable_id_columns(conn)
    return False


def _m17_stable_id_backfill(conn: sqlite3.Connection) -> bool:
    _backfill_stable_ids(conn)
    return False


def _m18_drop_track_mood_tags_fk(conn: sqlite3.Connection) -> bool:
    _drop_track_mood_tags_fk(conn)
    return False


# Ordered list of (version_number, migration_fn).
# Append new entries here; bump SCHEMA_VERSION accordingly.
_MIGRATIONS: list[tuple[int, Callable[[sqlite3.Connection], bool]]] = [
    (1,  _m01_rename_rating_key),
    (2,  _m02_rename_parent_rating_key),
    (3,  _m03_rename_art_rating_key),
    (4,  _m04_add_parent_item_key),
    (5,  _m05_add_track_index),
    (6,  _m06_add_view_count),
    (7,  _m07_add_last_viewed_at),
    (8,  _m08_add_image_key_tracks),
    (9,  _m09_add_results_subtitle_source_mode),
    (10, _m10_rename_plex_server_id),
    (11, _m11_lb_columns),
    (12, _m12_mood_tags_cluster_id),
    (13, _m13_audio_features_cluster_columns),
    (14, _m14_scheduled_playlists_schedule_type),
    (15, _m15_results_ai_columns),
    (16, _m16_stable_id_columns),
    (17, _m17_stable_id_backfill),
    (18, _m18_drop_track_mood_tags_fk),
]

# Migrations that change the tracks table structure and require a library
# re-sync to repopulate newly added / renamed columns.
_RESYNC_MIGRATIONS: frozenset[int] = frozenset({1, 2, 4, 5, 6, 7})


def init_schema(conn: sqlite3.Connection) -> bool:
    """Create tables and run any pending incremental migrations.

    Args:
        conn: An open database connection.

    Returns:
        True if a migration that requires a library re-sync was applied,
        False otherwise.
    """
    # 1. Always create / verify all tables (idempotent).
    _create_schema_tables(conn)

    # 2. Determine the highest migration already applied to this DB.
    row = conn.execute("SELECT version FROM schema_version").fetchone()
    current_version: int = row[0] if row else 0

    # 3. Fresh-database shortcut: all tables were just created with the full
    #    schema, so no migrations are needed. Jump straight to SCHEMA_VERSION.
    if current_version == 0 and not conn.execute("SELECT 1 FROM tracks LIMIT 1").fetchone():
        conn.execute("UPDATE schema_version SET version = ?", (SCHEMA_VERSION,))
        conn.commit()
        logger.info("Fresh database: schema initialised at version %d", SCHEMA_VERSION)
        return False

    # 4. Run only the migrations that have not been applied yet.
    resync_triggered = False
    for version, migration_fn in _MIGRATIONS:
        if version <= current_version:
            continue
        changed = migration_fn(conn)
        if changed and version in _RESYNC_MIGRATIONS:
            resync_triggered = True
        conn.execute("UPDATE schema_version SET version = ?", (version,))
        conn.commit()

    if current_version < SCHEMA_VERSION:
        logger.info(
            "Database migrated from version %d to %d (resync=%s)",
            current_version, SCHEMA_VERSION, resync_triggered,
        )

    return resync_triggered


# ---------------------------------------------------------------------------
# Private helpers used by migration functions
# (kept after init_schema so they can be referenced by the _mXX functions)
# ---------------------------------------------------------------------------


def _drop_track_mood_tags_fk(conn: sqlite3.Connection) -> None:
    """Recreate track_mood_tags without its FK to tracks(item_key).

    The full-replace resync does DELETE FROM tracks; that FK blocked it once
    mood data existed. Mood rows now survive via stable_id, so the FK is gone.
    One-shot: gated on the FK still being present.
    """
    fks = conn.execute("PRAGMA foreign_key_list(track_mood_tags)").fetchall()
    if not fks:
        return
    logger.info("Recreating track_mood_tags without FK to tracks…")
    conn.commit()  # ensure no open transaction before toggling FK enforcement
    conn.execute("PRAGMA foreign_keys=OFF")
    try:
        conn.executescript(
            """
            BEGIN;
            CREATE TABLE track_mood_tags_new (
                track_id       TEXT PRIMARY KEY,
                mood_primary   TEXT NOT NULL,
                mood_secondary TEXT,
                confidence     REAL,
                cluster_id     INTEGER,
                updated_at     TEXT NOT NULL DEFAULT (datetime('now')),
                stable_id      TEXT
            );
            INSERT INTO track_mood_tags_new
                (track_id, mood_primary, mood_secondary, confidence, cluster_id, updated_at, stable_id)
                SELECT track_id, mood_primary, mood_secondary, confidence, cluster_id, updated_at, stable_id
                FROM track_mood_tags;
            DROP TABLE track_mood_tags;
            ALTER TABLE track_mood_tags_new RENAME TO track_mood_tags;
            CREATE INDEX idx_track_mood_primary         ON track_mood_tags(mood_primary);
            CREATE INDEX idx_track_mood_secondary        ON track_mood_tags(mood_secondary);
            CREATE INDEX idx_track_mood_tags_stable_id   ON track_mood_tags(stable_id);
            COMMIT;
            """
        )
    finally:
        conn.execute("PRAGMA foreign_keys=ON")
    logger.info("track_mood_tags recreated without FK")


# Persistent track-derived tables and the column that currently holds the Roon
# item_key. stable_id is added alongside and backfilled from it.
_STABLE_ID_TABLES: dict[str, str] = {
    "tracks": "item_key",
    "track_audio_features": "item_key",
    "track_metadata_ext": "item_key",
    "clap_embeddings": "item_key",
    "lyrics_data": "item_key",
    "lyrics_embeddings": "item_key",
    "track_mood_tags": "track_id",
    "track_genres": "track_key",
}


def _ensure_stable_id_columns(conn: sqlite3.Connection) -> None:
    """Add a nullable stable_id column to tracks + every derived table (idempotent)."""
    for table in _STABLE_ID_TABLES:
        with contextlib.suppress(sqlite3.OperationalError):
            conn.execute(f"ALTER TABLE {table} ADD COLUMN stable_id TEXT")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_tracks_stable_id ON tracks(stable_id)")
    for table in _STABLE_ID_TABLES:
        if table == "tracks":
            continue
        conn.execute(
            f"CREATE INDEX IF NOT EXISTS idx_{table}_stable_id ON {table}(stable_id)"
        )
    conn.commit()


def _backfill_stable_ids(conn: sqlite3.Connection) -> None:
    """Populate stable_id for tracks and propagate to derived tables by
    joining on the (still-valid) item_key.

    Idempotent: only updates rows where stable_id IS NULL.
    """
    track_pending = conn.execute(
        "SELECT COUNT(*) FROM tracks WHERE stable_id IS NULL"
    ).fetchone()[0]
    if track_pending:
        from backend.stable_id import compute_stable_id  # noqa: PLC0415

        logger.info("Backfilling stable_id for %d tracks…", track_pending)
        rows = conn.execute(
            "SELECT item_key, artist, album, title, duration_ms FROM tracks "
            "WHERE stable_id IS NULL"
        ).fetchall()
        conn.executemany(
            "UPDATE tracks SET stable_id = ? WHERE item_key = ?",
            [
                (
                    compute_stable_id(r["artist"], r["album"], r["title"], r["duration_ms"]),
                    r["item_key"],
                )
                for r in rows
            ],
        )
        conn.commit()

    for table, keycol in _STABLE_ID_TABLES.items():
        if table == "tracks":
            continue
        try:
            has_null = conn.execute(
                f"SELECT 1 FROM {table} WHERE stable_id IS NULL LIMIT 1"
            ).fetchone()
            if not has_null:
                continue
            n = conn.execute(
                f"UPDATE {table} SET stable_id = ("
                f"  SELECT t.stable_id FROM tracks t WHERE t.item_key = {table}.{keycol}"
                f") WHERE stable_id IS NULL"
            ).rowcount
            conn.commit()
            logger.info("stable_id backfill: %s updated %d rows", table, n)
        except sqlite3.Error as e:
            conn.rollback()
            logger.warning("stable_id backfill skipped for %s: %s", table, e)


# ---------------------------------------------------------------------------
# Corruption repair
# ---------------------------------------------------------------------------


def repair_corrupt_indexes(conn: sqlite3.Connection) -> list[str]:
    """Run PRAGMA integrity_check and REINDEX any tables flagged as broken."""
    rows = conn.execute("PRAGMA integrity_check").fetchall()
    issues = [r[0] for r in rows if r[0] != "ok"]
    if not issues:
        return []

    logger.warning("SQLite integrity_check reported %d issue(s): %s",
                   len(issues), issues[:3])

    affected_tables: set[str] = set()
    import re  # noqa: PLC0415
    for msg in issues:
        match = re.search(r"index\s+(\S+)", msg)
        if not match:
            continue
        index_name = match.group(1)
        tbl_row = conn.execute(
            "SELECT tbl_name FROM sqlite_master WHERE type='index' AND name=?",
            (index_name,),
        ).fetchone()
        if tbl_row:
            affected_tables.add(tbl_row[0])

    for tbl in affected_tables:
        logger.warning("Rebuilding indexes on table '%s' (corruption detected)", tbl)
        conn.execute(f"REINDEX {tbl}")
    conn.commit()

    rows2 = conn.execute("PRAGMA integrity_check").fetchall()
    issues_after = [r[0] for r in rows2 if r[0] != "ok"]
    if issues_after:
        logger.error(
            "SQLite integrity_check still failing after REINDEX: %s",
            issues_after[:3],
        )
    else:
        logger.info("SQLite integrity restored via REINDEX on: %s",
                    sorted(affected_tables))
    return sorted(affected_tables)


# ---------------------------------------------------------------------------
# Initialization helpers
# ---------------------------------------------------------------------------


def ensure_db_initialized() -> sqlite3.Connection:
    """Open a connection and initialize the schema exactly once per process.

    Returns:
        An open, initialized sqlite3.Connection. Caller is responsible for
        closing it (or use the get_connection() context manager instead).
    """
    global _schema_initialized, _migration_applied
    conn = get_db_connection()

    if not _schema_initialized:
        with _schema_lock:
            if not _schema_initialized:
                _migration_applied = init_schema(conn)
                _schema_initialized = True

    return conn


def needs_resync() -> bool:
    """Return True if a schema migration requires the library to be re-synced."""
    return _migration_applied


def clear_migration_flag() -> None:
    """Clear the migration flag after a successful library sync."""
    global _migration_applied
    _migration_applied = False


# ---------------------------------------------------------------------------
# Context managers
# ---------------------------------------------------------------------------


@contextmanager
def get_connection() -> Generator[sqlite3.Connection, None, None]:
    """Yield an initialized sync connection and close it on exit.

    Usage::

        with get_connection() as conn:
            rows = conn.execute("SELECT ...").fetchall()
    """
    conn = ensure_db_initialized()
    try:
        yield conn
    finally:
        conn.close()


@asynccontextmanager
async def aget_connection():
    """Async context manager that yields an aiosqlite connection.

    Moves SQLite I/O off the event-loop thread via aiosqlite's internal
    thread executor. Schema must already be initialised (ensure_db_initialized
    is called at startup before any route handler runs).

    Usage::

        async with aget_connection() as conn:
            cursor = await conn.execute("SELECT ...")
            rows   = await cursor.fetchall()
    """
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    async with aiosqlite.connect(str(DB_PATH), timeout=30.0) as conn:
        conn.row_factory = aiosqlite.Row
        await conn.execute("PRAGMA journal_mode=WAL")
        await conn.execute("PRAGMA busy_timeout=5000")
        await conn.execute("PRAGMA foreign_keys=ON")
        yield conn


async def execute_write(query: str, params: tuple | list | None = None) -> None:
    """Run a single write statement on an aiosqlite connection."""
    async with aget_connection() as conn:
        await conn.execute(query, params or ())
        await conn.commit()
