"""Database migration functions for RoonSage."""

import contextlib
import logging
import sqlite3
from collections.abc import Callable

from backend.db.schema import _create_schema_tables
from backend.db.stable_id import (
    _backfill_stable_ids,
    _drop_track_mood_tags_fk,
    _ensure_stable_id_columns,
)

logger = logging.getLogger(__name__)

# Increment whenever a new migration is added at the bottom of _MIGRATIONS.
SCHEMA_VERSION = 19


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


def _m19_automations_then_actions(conn: sqlite3.Connection) -> bool:
    """Add ``then_actions`` JSON column so a primary action can chain follow-ups."""
    try:
        conn.execute(
            "ALTER TABLE automations ADD COLUMN then_actions TEXT DEFAULT '[]'"
        )
        logger.info("Migration 19: added automations.then_actions column")
        return True
    except sqlite3.OperationalError:
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
    (19, _m19_automations_then_actions),
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
