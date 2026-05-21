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

from backend.db import get_connection

logger = logging.getLogger(__name__)

# Active import tasks — keyed by source ('lastfm', 'listenbrainz')
_tasks: dict[str, asyncio.Task] = {}


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

    except Exception as exc:
        logger.exception("ListenBrainz import failed")
        _set_state(source, status="error", error_message=str(exc))
    finally:
        _resume_enrichment()
