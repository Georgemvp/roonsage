"""Database connection and schema management for RoonSage.

Provides get_db_connection(), init_schema(), ensure_db_initialized(),
needs_resync(), and the get_connection() context manager used by all
other cache modules.
"""

import logging
import sqlite3
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Generator

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

DATA_DIR = Path(__file__).parent.parent / "data"
DB_PATH = DATA_DIR / "library_cache.db"

# ---------------------------------------------------------------------------
# Module-level schema state
# ---------------------------------------------------------------------------

_schema_initialized = False
_schema_lock = threading.Lock()

# True when init_schema() applied at least one ALTER TABLE migration.
# Cleared by clear_migration_flag() after a successful library sync.
_migration_applied = False


# ---------------------------------------------------------------------------
# Connection helpers
# ---------------------------------------------------------------------------


def get_db_connection() -> sqlite3.Connection:
    """Open a WAL-mode SQLite connection with dict-like row access.

    Returns:
        sqlite3.Connection with row_factory=sqlite3.Row
    """
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(str(DB_PATH), timeout=30.0)
    conn.row_factory = sqlite3.Row

    # WAL mode: concurrent readers during writes
    conn.execute("PRAGMA journal_mode=WAL")
    # Busy timeout for lock contention
    conn.execute("PRAGMA busy_timeout=5000")
    # Enforce referential integrity
    conn.execute("PRAGMA foreign_keys=ON")

    return conn


# ---------------------------------------------------------------------------
# Schema management
# ---------------------------------------------------------------------------


def init_schema(conn: sqlite3.Connection) -> bool:
    """Create tables and indexes if they don't exist; apply incremental migrations.

    Args:
        conn: An open database connection.

    Returns:
        True if any ALTER TABLE migration was applied (signals need for re-sync),
        False if the schema was already up-to-date or was freshly created.
    """
    conn.executescript("""
        -- Tracks table: cached Roon track metadata
        CREATE TABLE IF NOT EXISTS tracks (
            item_key TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            album TEXT NOT NULL,
            duration_ms INTEGER,
            year INTEGER,
            genres TEXT,
            is_live BOOLEAN,
            parent_item_key TEXT,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        -- Indexes for common query patterns
        CREATE INDEX IF NOT EXISTS idx_tracks_artist ON tracks(artist);
        CREATE INDEX IF NOT EXISTS idx_tracks_year ON tracks(year);
        CREATE INDEX IF NOT EXISTS idx_tracks_is_live ON tracks(is_live);

        -- Sync state: single-row metadata table
        CREATE TABLE IF NOT EXISTS sync_state (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            roon_core_id TEXT,
            last_sync_at TIMESTAMP,
            track_count INTEGER DEFAULT 0,
            sync_duration_ms INTEGER
        );

        -- Ensure sync_state has exactly one row
        INSERT OR IGNORE INTO sync_state (id) VALUES (1);

        -- Albums table: direct store of Roon album metadata (populated during sync)
        CREATE TABLE IF NOT EXISTS albums (
            item_key TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            year INTEGER,
            genres TEXT,
            image_key TEXT,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        CREATE INDEX IF NOT EXISTS idx_albums_artist ON albums(artist);

        -- Genre junction table: one row per (track, genre) for fast SQL filtering
        CREATE TABLE IF NOT EXISTS track_genres (
            track_key TEXT NOT NULL,
            genre TEXT NOT NULL,
            PRIMARY KEY (track_key, genre),
            FOREIGN KEY (track_key) REFERENCES tracks(item_key)
        );
        CREATE INDEX IF NOT EXISTS idx_track_genres_genre ON track_genres(genre);

        -- Results table: persistent storage for generated playlists and recommendations
        CREATE TABLE IF NOT EXISTS results (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            title TEXT NOT NULL,
            prompt TEXT NOT NULL,
            snapshot JSON NOT NULL,
            track_count INTEGER NOT NULL,
            artist TEXT,
            art_item_key TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        CREATE INDEX IF NOT EXISTS idx_results_type_created ON results(type, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_results_created_at ON results(created_at DESC);
    """)

    # -----------------------------------------------------------------------
    # Incremental migrations (ALTER TABLE — idempotent via try/except)
    # -----------------------------------------------------------------------
    migrated = False

    # Migration: rename rating_key → item_key (Plex legacy → Roon naming)
    try:
        conn.execute("ALTER TABLE tracks RENAME COLUMN rating_key TO item_key")
        migrated = True
        logger.info("Migration applied: renamed rating_key to item_key in tracks")
    except sqlite3.OperationalError:
        pass  # Already renamed or column doesn't exist

    # Migration: rename parent_rating_key → parent_item_key
    try:
        conn.execute("ALTER TABLE tracks RENAME COLUMN parent_rating_key TO parent_item_key")
        migrated = True
        logger.info("Migration applied: renamed parent_rating_key to parent_item_key in tracks")
    except sqlite3.OperationalError:
        pass

    # Migration: rename art_rating_key → art_item_key in results table
    try:
        conn.execute("ALTER TABLE results RENAME COLUMN art_rating_key TO art_item_key")
        logger.info("Migration applied: renamed art_rating_key to art_item_key in results")
    except sqlite3.OperationalError:
        pass

    # Migration: add parent_item_key column if missing (very old databases)
    try:
        conn.execute("ALTER TABLE tracks ADD COLUMN parent_item_key TEXT")
        migrated = True
        logger.info("Migration applied: added parent_item_key column")
    except sqlite3.OperationalError:
        pass

    # Migration: add view_count and last_viewed_at columns for familiarity tracking
    try:
        conn.execute("ALTER TABLE tracks ADD COLUMN view_count INTEGER DEFAULT 0")
        migrated = True
        logger.info("Migration applied: added view_count column")
    except sqlite3.OperationalError:
        pass

    try:
        conn.execute("ALTER TABLE tracks ADD COLUMN last_viewed_at TEXT")
        migrated = True
        logger.info("Migration applied: added last_viewed_at column")
    except sqlite3.OperationalError:
        pass

    # Migration: add subtitle column to results table
    try:
        conn.execute("ALTER TABLE results ADD COLUMN subtitle TEXT")
        logger.info("Migration applied: added subtitle column to results")
    except sqlite3.OperationalError:
        pass

    # Migration: create track_genres table if it was added after the DB was created
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS track_genres (
            track_key TEXT NOT NULL,
            genre TEXT NOT NULL,
            PRIMARY KEY (track_key, genre),
            FOREIGN KEY (track_key) REFERENCES tracks(item_key)
        );
        CREATE INDEX IF NOT EXISTS idx_track_genres_genre ON track_genres(genre);
    """)

    # Migration: create albums table if it was added after the DB was created
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS albums (
            item_key TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            year INTEGER,
            genres TEXT,
            image_key TEXT,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS idx_albums_artist ON albums(artist);
    """)

    # Migration: rename plex_server_id to roon_core_id
    try:
        conn.execute("ALTER TABLE sync_state RENAME COLUMN plex_server_id TO roon_core_id")
        logger.info("Migration applied: renamed plex_server_id to roon_core_id")
    except sqlite3.OperationalError:
        pass

    # Index on parent_item_key (must come after migration adds the column)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_tracks_parent_key ON tracks(parent_item_key)")

    # -----------------------------------------------------------------------
    # Intelligence layer tables (MCP v5.0)
    # -----------------------------------------------------------------------
    conn.executescript("""
        -- Persistent taste profile: one row, updated in-place
        CREATE TABLE IF NOT EXISTS taste_profile (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            profile_json TEXT NOT NULL DEFAULT '{}'
        );
        INSERT OR IGNORE INTO taste_profile (id, profile_json) VALUES (1, '{}');

        -- Event log: every taste signal (playlist rated, feedback, skip, etc.)
        CREATE TABLE IF NOT EXISTS taste_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL DEFAULT (datetime('now')),
            event_type TEXT NOT NULL,
            data_json TEXT NOT NULL DEFAULT '{}'
        );
        CREATE INDEX IF NOT EXISTS idx_taste_events_ts ON taste_events(timestamp DESC);

        -- Passive listening history from Roon zones
        CREATE TABLE IF NOT EXISTS listening_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL DEFAULT (datetime('now')),
            zone_name TEXT,
            track_title TEXT,
            artist TEXT,
            album TEXT,
            genre TEXT,
            duration_seconds INTEGER,
            played_seconds INTEGER,
            skipped INTEGER DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_listening_ts ON listening_history(timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_listening_artist ON listening_history(artist);

        -- Saved playlists from curation sessions
        CREATE TABLE IF NOT EXISTS saved_playlists (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            prompt TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            source_mode TEXT DEFAULT 'library',
            track_count INTEGER DEFAULT 0,
            tracks_json TEXT,
            tags TEXT DEFAULT '',
            qobuz_playlist_id TEXT,
            rating INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_saved_playlists_created ON saved_playlists(created_at DESC);

        -- Similar artists for seed-based recommendations
        CREATE TABLE IF NOT EXISTS similar_artists (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            artist_name TEXT NOT NULL,
            similar_to TEXT NOT NULL,
            score REAL DEFAULT 0.5,
            source TEXT DEFAULT 'musicbrainz',
            UNIQUE(artist_name, similar_to)
        );
    """)

    # -----------------------------------------------------------------------
    # ListenBrain v6.0 migrations: enriched listening_history + lb_stats_cache
    # -----------------------------------------------------------------------

    # New columns in listening_history
    for col_def in [
        ("year", "INTEGER"),
        ("decade", "TEXT"),
        ("hour_of_day", "INTEGER"),
        ("day_of_week", "INTEGER"),
        ("source", "TEXT DEFAULT 'library'"),
    ]:
        col_name, col_type = col_def
        try:
            conn.execute(
                f"ALTER TABLE listening_history ADD COLUMN {col_name} {col_type}"
            )
            logger.info("Migration applied: added %s column to listening_history", col_name)
        except sqlite3.OperationalError:
            pass  # Column already exists

    # Migration: add played_pct column (skip detection v2 — proportional threshold)
    try:
        conn.execute("ALTER TABLE listening_history ADD COLUMN played_pct REAL")
        logger.info("Migration applied: added played_pct column to listening_history")
    except sqlite3.OperationalError:
        pass  # Column already exists

    # ListenBrainz stats cache table (single-row JSON cache per stat type)
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS lb_stats_cache (
            stat_type TEXT PRIMARY KEY,
            data_json TEXT NOT NULL DEFAULT '{}',
            range TEXT DEFAULT 'all_time',
            synced_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
    """)

    conn.commit()
    return migrated


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
    """Return True if a schema migration requires the library to be re-synced.

    Safe for fresh databases: _migration_applied is False when CREATE TABLE
    already includes all columns (ALTER TABLE operations are no-ops).
    """
    return _migration_applied


def clear_migration_flag() -> None:
    """Clear the migration flag after a successful library sync.

    Called by backend.sync.sync_library() once all tracks have been
    written with the new schema columns populated.
    """
    global _migration_applied
    _migration_applied = False


# ---------------------------------------------------------------------------
# Context manager
# ---------------------------------------------------------------------------


@contextmanager
def get_connection() -> Generator[sqlite3.Connection, None, None]:
    """Yield an initialized connection and close it on exit.

    Usage::

        with get_connection() as conn:
            rows = conn.execute("SELECT ...").fetchall()
    """
    conn = ensure_db_initialized()
    try:
        yield conn
    finally:
        conn.close()
