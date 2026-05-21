"""Cache-Powered Discovery — pure SQL queries against the local SQLite library cache.

All functions run zero LLM calls and zero external API calls. They read from:
  - tracks          (title, artist, album, item_key, parent_item_key)
  - listening_history (artist, track_title, album, timestamp, skipped)
  - track_genres    (track_key, genre)

All queries use get_connection() from backend.db so the schema is always
initialized before the first query runs.
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta

from backend.db import get_connection

logger = logging.getLogger(__name__)


def get_undiscovered_albums() -> list[dict]:
    """Library albums by the user's most-played artists, shuffled per artist.

    Album name matching between Last.fm and Roon is unreliable (different
    capitalization, "(Remastered)", "(Deluxe)" suffixes, etc.), so we don't
    filter by "unplayed". Instead we surface albums from familiar artists
    in a varied order so each page load shows different suggestions.

    Returns:
        Up to 20 dicts with keys: artist, album, parent_item_key, artist_play_count.
    """
    sql = """
        WITH artist_plays AS (
            SELECT
                artist,
                COUNT(*) AS play_count
            FROM listening_history
            WHERE artist IS NOT NULL
              AND artist != ''
              AND (skipped IS NULL OR skipped = 0)
            GROUP BY artist
            ORDER BY play_count DESC
            LIMIT 40
        ),
        artist_albums AS (
            SELECT DISTINCT
                a.artist,
                a.title    AS album,
                a.item_key AS parent_item_key,
                ap.play_count AS artist_play_count
            FROM albums a
            JOIN artist_plays ap ON LOWER(a.artist) = LOWER(ap.artist)
            WHERE a.title IS NOT NULL AND a.title != ''
        )
        SELECT artist, album, parent_item_key, artist_play_count
        FROM artist_albums
        ORDER BY artist_play_count DESC, RANDOM()
        LIMIT 20
    """
    try:
        with get_connection() as conn:
            rows = conn.execute(sql).fetchall()
            return [dict(r) for r in rows]
    except Exception:
        logger.exception("get_undiscovered_albums failed")
        return []


def get_deep_cuts() -> list[dict]:
    """Tracks by the top-20 artists (by listening history) played fewer than 5 times.

    These are the "album tracks the user keeps skipping" — deep cuts that the
    listener hasn't explored yet despite enjoying the artist.

    Returns:
        Up to 50 dicts with keys: title, artist, album, item_key, play_count.
    """
    sql = """
        WITH top_artists AS (
            SELECT
                artist,
                COUNT(*) AS play_count
            FROM listening_history
            WHERE artist IS NOT NULL
              AND artist != ''
              AND (skipped IS NULL OR skipped = 0)
            GROUP BY artist
            ORDER BY play_count DESC
            LIMIT 20
        ),
        track_plays AS (
            SELECT
                LOWER(artist)      AS artist_lower,
                LOWER(track_title) AS title_lower,
                COUNT(*)           AS play_count
            FROM listening_history
            WHERE artist IS NOT NULL AND track_title IS NOT NULL
            GROUP BY artist_lower, title_lower
        )
        SELECT
            t.title,
            t.artist,
            t.album,
            t.item_key,
            COALESCE(tp.play_count, 0) AS play_count
        FROM tracks t
        JOIN top_artists ta ON LOWER(t.artist) = LOWER(ta.artist)
        LEFT JOIN track_plays tp
            ON LOWER(t.artist) = tp.artist_lower
           AND LOWER(t.title)  = tp.title_lower
        WHERE COALESCE(tp.play_count, 0) < 5
          AND (t.is_live IS NULL OR t.is_live = 0)
        ORDER BY ta.play_count DESC, t.artist, t.album, t.title
        LIMIT 50
    """
    try:
        with get_connection() as conn:
            rows = conn.execute(sql).fetchall()
            return [dict(r) for r in rows]
    except Exception:
        logger.exception("get_deep_cuts failed")
        return []


def get_forgotten_favorites() -> list[dict]:
    """Tracks with 2+ total plays but no play in the last 14 days.

    Surfaces music the user used to love but hasn't revisited recently.

    Returns:
        Up to 30 dicts with keys: title, artist, album, item_key,
        total_plays, last_played_at.
    """
    cutoff = (datetime.now(tz=UTC) - timedelta(days=14)).strftime(
        "%Y-%m-%d %H:%M:%S"
    )
    sql = """
        WITH track_stats AS (
            SELECT
                LOWER(artist)      AS artist_lower,
                LOWER(track_title) AS title_lower,
                COUNT(*)           AS total_plays,
                MAX(timestamp)     AS last_played_at
            FROM listening_history
            WHERE artist IS NOT NULL AND track_title IS NOT NULL
              AND (skipped IS NULL OR skipped = 0)
            GROUP BY artist_lower, title_lower
            HAVING total_plays >= 2
               AND last_played_at < :cutoff
        )
        SELECT
            t.title,
            t.artist,
            t.album,
            t.item_key,
            ts.total_plays,
            ts.last_played_at
        FROM tracks t
        JOIN track_stats ts
            ON LOWER(t.artist) = ts.artist_lower
           AND LOWER(t.title)  = ts.title_lower
        WHERE (t.is_live IS NULL OR t.is_live = 0)
        ORDER BY ts.total_plays DESC
        LIMIT 30
    """
    try:
        with get_connection() as conn:
            rows = conn.execute(sql, {"cutoff": cutoff}).fetchall()
            return [dict(r) for r in rows]
    except Exception:
        logger.exception("get_forgotten_favorites failed")
        return []


def get_genre_explorer() -> list[dict]:
    """Aggregate genres from track_genres: how many artists and tracks per genre.

    Returns:
        List of dicts with keys: genre, artist_count, track_count,
        sorted by artist_count descending.
    """
    sql = """
        SELECT
            tg.genre,
            COUNT(DISTINCT t.artist) AS artist_count,
            COUNT(DISTINCT tg.track_key) AS track_count
        FROM track_genres tg
        JOIN tracks t ON t.item_key = tg.track_key
        WHERE tg.genre IS NOT NULL AND tg.genre != ''
        GROUP BY tg.genre
        ORDER BY artist_count DESC
    """
    try:
        with get_connection() as conn:
            rows = conn.execute(sql).fetchall()
            return [dict(r) for r in rows]
    except Exception:
        logger.exception("get_genre_explorer failed")
        return []
