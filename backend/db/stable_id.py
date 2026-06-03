"""Stable ID column management for RoonSage database."""

import contextlib
import logging
import sqlite3

logger = logging.getLogger(__name__)

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
