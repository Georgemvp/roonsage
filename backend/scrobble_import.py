"""Background import of historical scrobbles from Last.fm and ListenBrainz.

Imports into listening_history with source='lastfm' or source='listenbrainz'.
Progress is tracked in the scrobble_import_state table (created in db.py).
"""

from __future__ import annotations

import asyncio
import logging
from calendar import timegm
from datetime import UTC, datetime
from time import strptime
from typing import TYPE_CHECKING

from backend.db import get_connection

if TYPE_CHECKING:
    import sqlite3

logger = logging.getLogger(__name__)

# Active import tasks — keyed by source ('lastfm', 'listenbrainz', 'tag_enrich')
_tasks: dict[str, asyncio.Task] = {}

# ---------------------------------------------------------------------------
# Tag filtering helpers (shared by artist + track enrichment)
# ---------------------------------------------------------------------------

# Substrings that disqualify a Last.fm tag from being used as a genre.
_TAG_NOISE_SUBSTRINGS: tuple[str, ...] = (
    "seen live", "love", "favourit", "favorit", "amazing", "awesome",
    "spotify", "youtube", "apple music", "download", "mp3", "flac",
    "free music", "podcast", "radio", "all time", "best of",
)
# Exact (lowercased) tags to skip.
_TAG_NOISE_EXACT: frozenset[str] = frozenset({
    "best", "great", "classic", "beautiful", "perfect", "my", "good",
    "brilliant", "nice", "cool", "banger", "hot", "fire",
})


def _tags_to_genre(tags: list[dict], max_tags: int = 4) -> str | None:
    """Convert a Last.fm tag list to a comma-separated genre string.

    Filters out personal/noise tags; returns None when nothing useful remains.
    Tags should be sorted by count/popularity descending (Last.fm default).
    """
    genres: list[str] = []
    for tag in tags:
        name = tag.get("name", "").strip()
        if not name or len(name) < 3:
            continue
        nl = name.lower()
        if nl in _TAG_NOISE_EXACT:
            continue
        if any(s in nl for s in _TAG_NOISE_SUBSTRINGS):
            continue
        genres.append(name)
        if len(genres) >= max_tags:
            break
    return ", ".join(genres) if genres else None


# ---------------------------------------------------------------------------
# Last.fm tag enrichment for unmatched scrobbles
# ---------------------------------------------------------------------------

_tag_enrich_state: dict = {"status": "idle", "done": 0, "total": 0, "enriched": 0}


def get_tag_enrich_state() -> dict:
    return dict(_tag_enrich_state)


async def start_lastfm_tag_enrich(lf_client) -> bool:
    """Enrich unmatched scrobbles with genre via Last.fm artist.getTopTags.

    Returns False if already running.
    """
    if _tag_enrich_state.get("status") == "running":
        return False
    task = asyncio.create_task(_run_lastfm_tag_enrich(lf_client), name="lastfm_tag_enrich")
    _tasks["tag_enrich"] = task
    return True


async def _run_lastfm_tag_enrich(lf_client) -> None:
    global _tag_enrich_state  # noqa: PLW0603

    # Fetch distinct artists that still have unmatched (genre-less) scrobbles.
    with get_connection() as conn:
        artist_rows = conn.execute(
            """
            SELECT DISTINCT artist
            FROM listening_history
            WHERE source IN ('lastfm', 'listenbrainz')
              AND (genre IS NULL OR genre = '')
              AND artist IS NOT NULL AND artist != ''
            ORDER BY artist
            """
        ).fetchall()

    artists = [r[0] for r in artist_rows]
    total = len(artists)
    _tag_enrich_state = {"status": "running", "done": 0, "total": total, "enriched": 0}
    logger.info("Last.fm tag enrichment started: %d unique artists", total)

    pending: list[tuple[str, str]] = []  # (genre, artist)
    enriched = 0

    try:
        for i, artist in enumerate(artists):
            tags = await lf_client.get_artist_tags(artist)
            genre = _tags_to_genre(tags)
            if genre:
                pending.append((genre, artist))
                enriched += 1

            # Flush batch every 100 artists or at the end
            if len(pending) >= 100 or (i == total - 1 and pending):
                with get_connection() as conn:
                    conn.executemany(
                        """
                        UPDATE listening_history
                        SET genre = ?
                        WHERE LOWER(artist) = LOWER(?)
                          AND source IN ('lastfm', 'listenbrainz')
                          AND (genre IS NULL OR genre = '')
                        """,
                        pending,
                    )
                    conn.commit()
                pending.clear()

            _tag_enrich_state["done"] = i + 1
            _tag_enrich_state["enriched"] = enriched

            await asyncio.sleep(0.22)  # ≈4.5 req/s — safely under Last.fm's 5/s limit

        _tag_enrich_state["status"] = "complete"
        logger.info(
            "Last.fm tag enrichment done: %d/%d artists enriched",
            enriched,
            total,
        )

    except Exception as exc:
        logger.exception("Last.fm tag enrichment failed")
        _tag_enrich_state.update({"status": "error", "error": str(exc)})


def get_import_state(source: str) -> dict:
    """Return current import state for the given source."""
    with get_connection() as conn:
        row = conn.execute(
            "SELECT * FROM scrobble_import_state WHERE source = ?", (source,)
        ).fetchone()
        if row:
            return dict(row)
    return {
        "source": source,
        "status": "idle",
        "total_imported": 0,
        "last_ts": None,
        "started_at": None,
        "completed_at": None,
        "error_message": None,
    }


def is_running(source: str) -> bool:
    task = _tasks.get(source)
    return task is not None and not task.done()


def _set_state(source: str, **kwargs) -> None:
    with get_connection() as conn:
        existing = conn.execute(
            "SELECT source FROM scrobble_import_state WHERE source = ?", (source,)
        ).fetchone()
        if existing:
            sets = ", ".join(f"{k} = ?" for k in kwargs)
            conn.execute(
                f"UPDATE scrobble_import_state SET {sets} WHERE source = ?",
                [*kwargs.values(), source],
            )
        else:
            kwargs["source"] = source
            cols = ", ".join(kwargs.keys())
            placeholders = ", ".join("?" * len(kwargs))
            conn.execute(
                f"INSERT INTO scrobble_import_state ({cols}) VALUES ({placeholders})",
                list(kwargs.values()),
            )
        conn.commit()


def _insert_batch(rows: list[tuple]) -> int:
    """Insert rows into listening_history, skip duplicates. Returns inserted count."""
    if not rows:
        return 0
    with get_connection() as conn:
        result = conn.executemany(
            """
            INSERT OR IGNORE INTO listening_history
                (timestamp, zone_name, track_title, artist, album,
                 genre, duration_seconds, played_seconds, skipped,
                 year, decade, hour_of_day, day_of_week, source, played_pct)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            rows,
        )
        conn.commit()
        return result.rowcount


def enrich_imported_genres(conn: sqlite3.Connection) -> int:
    """Fast SQL backfill of genre + release-year/decade for imported scrobbles.

    Matches rows (source='lastfm'/'listenbrainz') to the library ``tracks``
    table by exact lowercased title + artist, then:
    - copies genre tags from ``track_genres``
    - overwrites year/decade with the track's actual release year (more
      accurate than the scrobble-timestamp year stored at import time)

    Returns the number of rows updated.
    Called automatically at the end of each import run and on startup.
    """
    result = conn.execute(
        """
        UPDATE listening_history
        SET
            genre = (
                SELECT GROUP_CONCAT(sub.genre, ', ')
                FROM (
                    SELECT DISTINCT tg.genre
                    FROM track_genres tg
                    JOIN tracks t ON t.item_key = tg.track_key
                    WHERE LOWER(t.title)  = LOWER(listening_history.track_title)
                      AND LOWER(t.artist) = LOWER(listening_history.artist)
                    ORDER BY tg.genre
                ) AS sub
            ),
            year = COALESCE(
                (SELECT t.year FROM tracks t
                 WHERE LOWER(t.title)  = LOWER(listening_history.track_title)
                   AND LOWER(t.artist) = LOWER(listening_history.artist)
                   AND t.year IS NOT NULL AND t.year > 0
                 LIMIT 1),
                year
            ),
            decade = COALESCE(
                (SELECT CAST((t.year / 10) * 10 AS TEXT) || 's' FROM tracks t
                 WHERE LOWER(t.title)  = LOWER(listening_history.track_title)
                   AND LOWER(t.artist) = LOWER(listening_history.artist)
                   AND t.year IS NOT NULL AND t.year > 0
                 LIMIT 1),
                decade
            )
        WHERE source IN ('lastfm', 'listenbrainz')
          AND track_title IS NOT NULL AND artist IS NOT NULL
        """
    )
    conn.commit()
    return result.rowcount


def _ts_to_row(uts: int, title: str, artist: str, album: str, source: str) -> tuple:
    """Convert a unix timestamp + track info to a listening_history row tuple."""
    dt = datetime.fromtimestamp(uts, tz=UTC)
    ts_str = dt.strftime("%Y-%m-%d %H:%M:%S")
    year = dt.year
    decade = f"{(year // 10) * 10}s"
    hour = dt.hour
    dow = dt.weekday()
    return (ts_str, None, title, artist, album, None, None, None, 0, year, decade, hour, dow, source, None)


async def start_lastfm_import(lf_client, from_year: int = 2014) -> bool:
    """Start a background Last.fm history import. Returns False if already running."""
    source = "lastfm"
    if is_running(source):
        return False
    _set_state(
        source,
        status="running",
        total_imported=0,
        started_at=datetime.now(tz=UTC).strftime("%Y-%m-%d %H:%M:%S"),
        completed_at=None,
        error_message=None,
    )
    task = asyncio.create_task(_run_lastfm_import(lf_client, from_year))
    _tasks[source] = task
    return True


def _pause_enrichment() -> None:
    try:
        from backend.enrichment_worker import get_worker  # noqa: PLC0415
        get_worker().pause()
        logger.info("Enrichment worker paused during scrobble import")
    except Exception as exc:
        logger.warning("Could not pause enrichment worker: %s", exc)


def _resume_enrichment() -> None:
    try:
        from backend.enrichment_worker import get_worker  # noqa: PLC0415
        w = get_worker()
        if w.is_paused() and not is_running("lastfm") and not is_running("listenbrainz"):
            w.resume()
            logger.info("Enrichment worker resumed after scrobble import")
    except Exception as exc:
        logger.warning("Could not resume enrichment worker: %s", exc)


async def _run_lastfm_import(lf_client, from_year: int) -> None:
    source = "lastfm"
    from_ts = int(timegm(strptime(f"{from_year}-01-01", "%Y-%m-%d")))
    total = 0
    page = 1

    _pause_enrichment()
    try:
        while True:
            data = await lf_client.get_recent_tracks(from_ts=from_ts, page=page, limit=200)
            if data is None:
                logger.warning("Last.fm import: no data on page %d, stopping", page)
                break

            rt = data.get("recenttracks", {})
            tracks = rt.get("track", [])
            attr = rt.get("@attr", {})
            total_pages = int(attr.get("totalPages", 1))

            if isinstance(tracks, dict):
                tracks = [tracks]

            batch = []
            for t in tracks:
                date_info = t.get("date")
                if not date_info:
                    continue  # skip currently-playing
                uts = int(date_info.get("uts", 0))
                if uts == 0:
                    continue
                artist_raw = t.get("artist", {})
                artist = artist_raw.get("#text", "") if isinstance(artist_raw, dict) else str(artist_raw)
                title = t.get("name", "")
                album_raw = t.get("album", {})
                album = album_raw.get("#text", "") if isinstance(album_raw, dict) else str(album_raw)
                if not title or not artist:
                    continue
                batch.append(_ts_to_row(uts, title, artist, album, source))

            inserted = _insert_batch(batch)
            total += inserted
            _set_state(source, total_imported=total)

            logger.info("Last.fm import: page %d/%d — %d new rows (total %d)", page, total_pages, inserted, total)

            if page >= total_pages:
                break
            page += 1
            await asyncio.sleep(0.25)  # stay within Last.fm's ~5 req/s limit

        _set_state(
            source,
            status="complete",
            total_imported=total,
            completed_at=datetime.now(tz=UTC).strftime("%Y-%m-%d %H:%M:%S"),
        )
        logger.info("Last.fm import complete: %d tracks imported", total)

        # Backfill genre/year/decade from library for all imported rows
        with get_connection() as enrich_conn:
            enriched = enrich_imported_genres(enrich_conn)
            logger.info("Last.fm post-import enrichment: %d rows updated with genre/year", enriched)

    except Exception as exc:
        logger.exception("Last.fm import failed")
        _set_state(source, status="error", error_message=str(exc))
    finally:
        _resume_enrichment()


async def start_lb_import(lb_client, from_year: int = 2014) -> bool:
    """Start a background ListenBrainz history import. Returns False if already running."""
    source = "listenbrainz"
    if is_running(source):
        return False
    _set_state(
        source,
        status="running",
        total_imported=0,
        started_at=datetime.now(tz=UTC).strftime("%Y-%m-%d %H:%M:%S"),
        completed_at=None,
        error_message=None,
    )
    task = asyncio.create_task(_run_lb_import(lb_client, from_year))
    _tasks[source] = task
    return True


async def _run_lb_import(lb_client, from_year: int) -> None:
    source = "listenbrainz"
    min_ts = int(timegm(strptime(f"{from_year}-01-01", "%Y-%m-%d")))
    total = 0
    max_ts = None  # Start from now, paginate backwards

    _pause_enrichment()
    try:
        while True:
            listens = await lb_client.get_listens(min_ts=min_ts, max_ts=max_ts, count=100)
            if not listens:
                break

            batch = []
            oldest_ts = None
            for listen in listens:
                uts = listen.get("listened_at", 0)
                if uts == 0:
                    continue
                if uts < min_ts:
                    continue
                meta = listen.get("track_metadata", {})
                title = meta.get("track_name", "")
                artist = meta.get("artist_name", "")
                release = meta.get("release_name", "") or ""
                if not title or not artist:
                    continue
                batch.append(_ts_to_row(uts, title, artist, release, source))
                if oldest_ts is None or uts < oldest_ts:
                    oldest_ts = uts

            inserted = _insert_batch(batch)
            total += inserted
            _set_state(source, total_imported=total)

            logger.info("ListenBrainz import: batch of %d listens, %d new (total %d)", len(listens), inserted, total)

            if oldest_ts is None or oldest_ts <= min_ts:
                break
            # Paginate: get listens before the oldest one we just saw
            max_ts = oldest_ts - 1
            await asyncio.sleep(0.1)

        _set_state(
            source,
            status="complete",
            total_imported=total,
            completed_at=datetime.now(tz=UTC).strftime("%Y-%m-%d %H:%M:%S"),
        )
        logger.info("ListenBrainz import complete: %d tracks imported", total)

        # Backfill genre/year/decade from library for all imported rows
        with get_connection() as enrich_conn:
            enriched = enrich_imported_genres(enrich_conn)
            logger.info("LB post-import enrichment: %d rows updated with genre/year", enriched)

    except Exception as exc:
        logger.exception("ListenBrainz import failed")
        _set_state(source, status="error", error_message=str(exc))
    finally:
        _resume_enrichment()
