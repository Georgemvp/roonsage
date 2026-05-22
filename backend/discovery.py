"""Cache-Powered Discovery — pure SQL + LB/Last.fm cache queries.

Reads from:
  - tracks / albums / track_genres   (Roon library cache)
  - listening_history                (Last.fm / ListenBrainz scrobbles)
  - lb_stats_cache                   (LB top_releases, top_recordings, feedback_loved)
"""

from __future__ import annotations

import json
import logging
from collections import defaultdict
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


_RELEASE_SUFFIXES = (
    " (remastered)", " (remastered edition)", " (deluxe edition)",
    " (deluxe)", " (deluxe version)", " (special edition)",
    " (expanded edition)", " (anniversary edition)",
)


def _build_album_index(conn) -> tuple[dict, dict]:
    """Load all albums into two lookup dicts (single query).

    Returns:
        exact_map: (artist_lower, title_lower) → row
        artist_map: artist_lower → [row, ...]
    """
    rows = conn.execute(
        "SELECT title, artist, item_key, LOWER(artist) AS al, LOWER(title) AS tl FROM albums"
    ).fetchall()
    exact_map: dict[tuple[str, str], object] = {}
    artist_map: dict[str, list] = defaultdict(list)
    for r in rows:
        key = (r["al"], r["tl"])
        exact_map[key] = r
        artist_map[r["al"]].append(r)
    return exact_map, artist_map


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
            # Single query instead of N queries per release
            exact_map, artist_map = _build_album_index(conn)

        results: list[dict] = []
        seen_keys: set[str] = set()

        for rel in releases:
            artist = rel.get("artist_name", "")
            title = rel.get("release_name", "")
            listen_count = rel.get("listen_count", 0)
            if not artist or not title:
                continue

            al = artist.lower()
            tl = title.lower()

            candidates = [tl]
            for suffix in _RELEASE_SUFFIXES:
                if tl.endswith(suffix):
                    candidates.append(tl[: -len(suffix)])

            match = None
            for candidate in candidates:
                # Exact match
                match = exact_map.get((al, candidate))
                if match:
                    break
                # Substring match within albums for this artist
                for album_row in artist_map.get(al, []):
                    if candidate in album_row["tl"]:
                        match = album_row
                        break
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

            # Load tracks into a lookup structure (single query replaces per-track queries)
            track_rows = conn.execute(
                """SELECT title, artist, item_key,
                          LOWER(artist) AS al, LOWER(title) AS tl
                   FROM tracks WHERE is_live IS NULL OR is_live = 0"""
            ).fetchall()

        # Build: title_lower → [(row, artist_lower), ...]
        title_map: dict[str, list] = defaultdict(list)
        for r in track_rows:
            title_map[r["tl"]].append(r)

        results: list[dict] = []
        seen_keys: set[str] = set()

        for entry in loved:
            meta = entry.get("track_metadata") or {}
            artist = meta.get("artist_name", "")
            title = meta.get("track_name", "")
            if not artist or not title:
                continue

            al = artist.lower()
            tl = title.lower()
            match = None
            for r in title_map.get(tl, []):
                if al in r["al"]:  # substring match (like original LIKE %artist%)
                    match = r
                    break

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
    """Max 2 random tracks per artist from top-40, played fewer than 5 times.

    Returns:
        Up to 40 dicts: title, artist, album, item_key, play_count.
    """
    sql = """
        WITH top_artists AS (
            SELECT artist, COUNT(*) AS play_count
            FROM listening_history
            WHERE artist IS NOT NULL AND artist != ''
              AND (skipped IS NULL OR skipped = 0)
            GROUP BY artist
            ORDER BY play_count DESC
            LIMIT 40
        ),
        track_plays AS (
            SELECT
                LOWER(artist)      AS artist_lower,
                LOWER(track_title) AS title_lower,
                COUNT(*)           AS play_count
            FROM listening_history
            WHERE artist IS NOT NULL AND track_title IS NOT NULL
            GROUP BY artist_lower, title_lower
        ),
        deduped AS (
            -- One row per unique (artist, title) — pick any item_key
            SELECT
                MIN(t.item_key) AS item_key,
                t.title,
                t.artist,
                COALESCE(tp.play_count, 0) AS play_count
            FROM tracks t
            JOIN top_artists ta ON LOWER(t.artist) = LOWER(ta.artist)
            LEFT JOIN track_plays tp
                ON LOWER(t.artist) = tp.artist_lower
               AND LOWER(t.title)  = tp.title_lower
            WHERE COALESCE(tp.play_count, 0) < 5
              AND (t.is_live IS NULL OR t.is_live = 0)
            GROUP BY t.artist, LOWER(t.title)
        ),
        candidates AS (
            SELECT
                item_key, title, artist, play_count,
                ROW_NUMBER() OVER (PARTITION BY artist ORDER BY RANDOM()) AS rn
            FROM deduped
        )
        SELECT title, artist, '' AS album, item_key, play_count
        FROM candidates
        WHERE rn <= 2
        ORDER BY RANDOM()
        LIMIT 40
    """
    try:
        with get_connection() as conn:
            rows = conn.execute(sql).fetchall()
            return [dict(r) for r in rows]
    except Exception:
        logger.exception("get_deep_cuts failed")
        return []


def get_forgotten_favorites() -> list[dict]:
    """Max 2 forgotten tracks per artist, randomised each load.

    Tracks with 3+ total plays but not played in the last 30 days.

    Returns:
        Up to 30 dicts: title, artist, album, item_key, total_plays, last_played_at.
    """
    cutoff = (datetime.now(tz=UTC) - timedelta(days=30)).strftime("%Y-%m-%d %H:%M:%S")
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
            HAVING total_plays >= 3
               AND last_played_at < :cutoff
        ),
        deduped AS (
            -- One row per unique (artist, title) — avoid duplicates from multiple editions
            SELECT
                MIN(t.item_key) AS item_key,
                t.artist,
                ts.artist_lower,
                ts.title_lower,
                ts.total_plays,
                ts.last_played_at
            FROM tracks t
            JOIN track_stats ts
                ON LOWER(t.artist) = ts.artist_lower
               AND LOWER(t.title)  = ts.title_lower
            WHERE (t.is_live IS NULL OR t.is_live = 0)
            GROUP BY t.artist, ts.title_lower
        ),
        candidates AS (
            SELECT
                d.item_key,
                t.title,
                d.artist,
                d.total_plays,
                d.last_played_at,
                ROW_NUMBER() OVER (PARTITION BY d.artist ORDER BY RANDOM()) AS rn
            FROM deduped d
            JOIN tracks t ON t.item_key = d.item_key
        )
        SELECT title, artist, '' AS album, item_key, total_plays, last_played_at
        FROM candidates
        WHERE rn <= 2
        ORDER BY RANDOM()
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
