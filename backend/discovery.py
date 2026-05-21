"""Cache-Powered Discovery — pure SQL + LB/Last.fm cache queries.

Reads from:
  - tracks / albums / track_genres   (Roon library cache)
  - listening_history                (Last.fm / ListenBrainz scrobbles)
  - lb_stats_cache                   (LB top_releases, top_recordings, feedback_loved)
"""

from __future__ import annotations

import json
import logging
from datetime import UTC, datetime, timedelta

from backend.db import get_connection

logger = logging.getLogger(__name__)


def get_favorites_in_library() -> list[dict]:
    """One random album per top-40 artist so every artist gets a slot.

    Uses ROW_NUMBER() OVER (PARTITION BY artist ORDER BY RANDOM()) so each
    refresh shows a different album per artist, and Mark Knopfler never fills
    all 20 slots.

    Returns:
        Up to 20 dicts: artist, album, parent_item_key, artist_play_count.
    """
    sql = """
        WITH artist_plays AS (
            SELECT artist, COUNT(*) AS play_count
            FROM listening_history
            WHERE artist IS NOT NULL AND artist != ''
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
        ),
        ranked AS (
            SELECT *,
                ROW_NUMBER() OVER (PARTITION BY artist ORDER BY RANDOM()) AS rn
            FROM artist_albums
        )
        SELECT artist, album, parent_item_key, artist_play_count
        FROM ranked
        WHERE rn = 1
        ORDER BY artist_play_count DESC
        LIMIT 20
    """
    try:
        with get_connection() as conn:
            rows = conn.execute(sql).fetchall()
            return [dict(r) for r in rows]
    except Exception:
        logger.exception("get_favorites_in_library failed")
        return []


def get_lb_top_releases_in_library() -> list[dict]:
    """LB top_releases matched against the Roon library.

    Fetches the user's 50 most-listened albums from lb_stats_cache, then
    looks up each one in the albums table by artist+title (case-insensitive,
    strips common suffixes like Remastered/Deluxe for a fuzzy match).

    Returns:
        Up to 15 dicts: artist, album, parent_item_key, listen_count.
        Sorted by LB listen_count descending.
    """
    try:
        with get_connection() as conn:
            row = conn.execute(
                "SELECT data_json FROM lb_stats_cache WHERE stat_type = 'top_releases' LIMIT 1"
            ).fetchone()
            if not row:
                return []

            releases = json.loads(row[0])

            results: list[dict] = []
            seen_keys: set[str] = set()

            for rel in releases:
                artist = rel.get("artist_name", "")
                title = rel.get("release_name", "")
                listen_count = rel.get("listen_count", 0)
                if not artist or not title:
                    continue

                # Try exact match first, then strip suffix variants
                candidates = [title]
                for suffix in [
                    " (Remastered)", " (Remastered Edition)", " (Deluxe Edition)",
                    " (Deluxe)", " (Deluxe Version)", " (Special Edition)",
                    " (Expanded Edition)", " (Anniversary Edition)",
                ]:
                    if title.endswith(suffix):
                        candidates.append(title[: -len(suffix)])

                match = None
                for candidate in candidates:
                    match = conn.execute(
                        """SELECT title, artist, item_key FROM albums
                           WHERE LOWER(artist) = LOWER(?)
                             AND LOWER(title)  = LOWER(?)
                           LIMIT 1""",
                        (artist, candidate),
                    ).fetchone()
                    if match:
                        break

                    # Also try: library title contains candidate
                    match = conn.execute(
                        """SELECT title, artist, item_key FROM albums
                           WHERE LOWER(artist) = LOWER(?)
                             AND LOWER(title) LIKE ?
                           LIMIT 1""",
                        (artist, f"%{candidate.lower()}%"),
                    ).fetchone()
                    if match:
                        break

                if match and match["item_key"] not in seen_keys:
                    seen_keys.add(match["item_key"])
                    results.append({
                        "artist": match["artist"],
                        "album": match["title"],
                        "parent_item_key": match["item_key"],
                        "listen_count": listen_count,
                    })
                    if len(results) >= 15:
                        break

            return results

    except Exception:
        logger.exception("get_lb_top_releases_in_library failed")
        return []


def get_lb_loved_in_library() -> list[dict]:
    """ListenBrainz loved tracks that exist in the Roon library.

    Matches feedback_loved tracks against the tracks table by artist+title
    (case-insensitive). Returns up to 20 unique tracks.

    Returns:
        Up to 20 dicts: title, artist, item_key.
    """
    try:
        with get_connection() as conn:
            row = conn.execute(
                "SELECT data_json FROM lb_stats_cache WHERE stat_type = 'feedback_loved' LIMIT 1"
            ).fetchone()
            if not row:
                return []

            loved = json.loads(row[0])

            results: list[dict] = []
            seen_keys: set[str] = set()

            for entry in loved:
                meta = entry.get("track_metadata") or {}
                artist = meta.get("artist_name", "")
                title = meta.get("track_name", "")
                if not artist or not title:
                    continue

                match = conn.execute(
                    """SELECT title, artist, item_key FROM tracks
                       WHERE LOWER(artist) LIKE ?
                         AND LOWER(title)  = LOWER(?)
                         AND (is_live IS NULL OR is_live = 0)
                       LIMIT 1""",
                    (f"%{artist.lower()}%", title),
                ).fetchone()

                if match and match["item_key"] not in seen_keys:
                    seen_keys.add(match["item_key"])
                    results.append({
                        "title": match["title"],
                        "artist": match["artist"],
                        "item_key": match["item_key"],
                    })
                    if len(results) >= 20:
                        break

            return results

    except Exception:
        logger.exception("get_lb_loved_in_library failed")
        return []


def get_deep_cuts() -> list[dict]:
    """Tracks by the top-20 artists (by listening history) played fewer than 5 times.

    Returns:
        Up to 50 dicts: title, artist, album, item_key, play_count.
    """
    sql = """
        WITH top_artists AS (
            SELECT artist, COUNT(*) AS play_count
            FROM listening_history
            WHERE artist IS NOT NULL AND artist != ''
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

    Returns:
        Up to 30 dicts: title, artist, album, item_key, total_plays, last_played_at.
    """
    cutoff = (datetime.now(tz=UTC) - timedelta(days=14)).strftime("%Y-%m-%d %H:%M:%S")
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
    """Aggregate genres from track_genres.

    Returns:
        List of dicts: genre, artist_count, track_count.
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
