"""Background enrichment worker for RoonSage Metadata Enrichment Pipeline (v10.0).

Reads tracks from ``enrichment_queue``, fetches metadata from MusicBrainz
(always) and Last.fm (when configured), then writes results to
``track_metadata_ext``.

Rate limits (per MusicBrainz / Last.fm policy):
  MusicBrainz : 1 req/s  — enforced by musicbrainz_client._mb_semaphore
  Last.fm      : 5 req/s  — enforced by a per-worker semaphore below

Design notes:
  - Single asyncio task; processing is sequential, not concurrent.
  - Items are processed one-at-a-time from the queue.  The BATCH_SIZE
    constant controls how many items are pulled in a single DB query to
    avoid locking the table for too long.
  - On failure the item's ``attempts`` counter is incremented; after
    MAX_ATTEMPTS the item is marked ``failed`` and skipped permanently.
  - A pause/resume mechanism uses a threading.Event so the REST API can
    stop the worker without cancelling the asyncio task.
"""

import asyncio
import json
import logging
import sqlite3
from datetime import datetime, timezone
from typing import Optional

logger = logging.getLogger(__name__)

# ------------------------------------------------------------------
# Configuration constants
# ------------------------------------------------------------------

BATCH_SIZE = 100          # Max pending items to pull per batch
BATCH_PAUSE_SECONDS = 60  # Sleep between batches when no work is left
ITEM_SLEEP_SECONDS = 0.2  # Tiny pause between individual items (LF rate headroom)
MAX_ATTEMPTS = 3          # Retry failed items up to this many times

# Last.fm rate: 5 req/s
_lf_semaphore = asyncio.Semaphore(5)
_LF_SLEEP = 0.21  # seconds after releasing the LF semaphore


# ===========================================================================
# Queue management helpers
# ===========================================================================


def populate_enrichment_queue(conn: sqlite3.Connection) -> int:
    """Insert un-enriched tracks into ``enrichment_queue``.

    Skips:
    - Tracks that already have a row in ``track_metadata_ext`` (complete or pending).
    - If the queue already has > 500 pending items (avoid unbounded growth).

    Returns the number of newly inserted rows.
    """
    # Check current pending count
    row = conn.execute(
        "SELECT COUNT(*) FROM enrichment_queue WHERE status = 'pending'"
    ).fetchone()
    pending = row[0] if row else 0
    if pending > 500:
        logger.info(
            "Enrichment queue already has %d pending items — skipping populate", pending
        )
        return 0

    # Find tracks missing from track_metadata_ext (either table row absent
    # or not yet in enrichment_queue at all)
    conn.execute("""
        INSERT OR IGNORE INTO enrichment_queue (item_key, artist, title, album)
        SELECT t.item_key, t.artist, t.title, t.album
        FROM tracks t
        LEFT JOIN track_metadata_ext me ON me.item_key = t.item_key
        WHERE me.item_key IS NULL
    """)
    count = conn.execute(
        "SELECT changes()"
    ).fetchone()[0]
    conn.commit()
    logger.info("Enrichment queue populated: %d new items inserted", count)
    return count


def get_queue_stats(conn: sqlite3.Connection) -> dict:
    """Return counts for each status value in ``enrichment_queue``."""
    rows = conn.execute(
        "SELECT status, COUNT(*) as cnt FROM enrichment_queue GROUP BY status"
    ).fetchall()
    stats: dict[str, int] = {
        "pending": 0,
        "processing": 0,
        "complete": 0,
        "failed": 0,
    }
    for row in rows:
        stats[row["status"]] = row["cnt"]

    # Also report total enriched (rows in track_metadata_ext)
    total = conn.execute("SELECT COUNT(*) FROM track_metadata_ext").fetchone()[0]
    stats["enriched_total"] = total
    stats["mb_matches"] = conn.execute(
        "SELECT COUNT(*) FROM track_metadata_ext WHERE musicbrainz_id IS NOT NULL"
    ).fetchone()[0]
    stats["lastfm_matches"] = conn.execute(
        "SELECT COUNT(*) FROM track_metadata_ext WHERE lastfm_tags IS NOT NULL"
    ).fetchone()[0]
    return stats


# ===========================================================================
# Per-item enrichment logic
# ===========================================================================


async def _fetch_lastfm(artist: str, title: str) -> tuple[list[str], int | None, int | None]:
    """Fetch Last.fm track info: (tags, listeners, playcount).

    Returns ([], None, None) when Last.fm is not configured or the call fails.
    """
    from backend.lastfm_client import get_lf_client  # noqa: PLC0415

    lf_client = get_lf_client()
    if lf_client is None or not lf_client.is_configured():
        return [], None, None

    async with _lf_semaphore:
        track_info = await lf_client.get_track_info(artist, title)
        await asyncio.sleep(_LF_SLEEP)

    if not track_info:
        return [], None, None

    raw_tags: list[str] = []
    toptags = track_info.get("toptags", {})
    for tag in toptags.get("tag", []):
        name = tag.get("name", "").strip()
        if name:
            raw_tags.append(name)

    listeners: int | None = None
    playcount: int | None = None
    try:
        listeners = int(track_info.get("listeners", 0)) or None
    except (ValueError, TypeError):
        pass
    try:
        playcount = int(track_info.get("playcount", 0)) or None
    except (ValueError, TypeError):
        pass

    return raw_tags, listeners, playcount


async def enrich_one(
    item_key: str,
    artist: str,
    title: str,
    conn: sqlite3.Connection,
) -> bool:
    """Enrich a single track.  Returns True on success, False on failure."""
    from backend.musicbrainz_client import get_mb_client  # noqa: PLC0415

    mb_client = get_mb_client()
    try:
        mbid, mb_tags, mb_release_date, mb_country = await mb_client.lookup_recording(
            artist, title
        )
    except Exception as exc:
        logger.warning("MB lookup failed for %s - %s: %s", artist, title, exc)
        mbid, mb_tags, mb_release_date, mb_country = None, [], None, None

    try:
        lf_tags, lf_listeners, lf_playcount = await _fetch_lastfm(artist, title)
    except Exception as exc:
        logger.warning("LF lookup failed for %s - %s: %s", artist, title, exc)
        lf_tags, lf_listeners, lf_playcount = [], None, None

    # Determine enrichment_source
    has_mb = bool(mbid)
    has_lf = bool(lf_tags or lf_listeners is not None)
    if has_mb and has_lf:
        source = "both"
    elif has_mb:
        source = "musicbrainz"
    elif has_lf:
        source = "lastfm"
    else:
        # Nothing found — still write a row so we don't retry forever
        source = "none"

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    try:
        conn.execute("""
            INSERT INTO track_metadata_ext
                (item_key, musicbrainz_id, mb_tags, mb_release_date, mb_country,
                 lastfm_tags, lastfm_listeners, lastfm_playcount,
                 enriched_at, enrichment_source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(item_key) DO UPDATE SET
                musicbrainz_id     = excluded.musicbrainz_id,
                mb_tags            = excluded.mb_tags,
                mb_release_date    = excluded.mb_release_date,
                mb_country         = excluded.mb_country,
                lastfm_tags        = excluded.lastfm_tags,
                lastfm_listeners   = excluded.lastfm_listeners,
                lastfm_playcount   = excluded.lastfm_playcount,
                enriched_at        = excluded.enriched_at,
                enrichment_source  = excluded.enrichment_source
        """, (
            item_key,
            mbid,
            json.dumps(mb_tags) if mb_tags else None,
            mb_release_date,
            mb_country,
            json.dumps(lf_tags) if lf_tags else None,
            lf_listeners,
            lf_playcount,
            now,
            source,
        ))
        conn.execute("""
            UPDATE enrichment_queue
            SET status = 'complete', processed_at = ?
            WHERE item_key = ?
        """, (now, item_key))
        conn.commit()
        return True
    except Exception as exc:
        logger.error("DB write failed for enrichment of %s: %s", item_key, exc)
        conn.rollback()
        return False


# ===========================================================================
# EnrichmentWorker class
# ===========================================================================


class EnrichmentWorker:
    """Background task that enriches library tracks with external metadata.

    Start with ``asyncio.create_task(worker.run())``.  Control with
    ``worker.pause()`` / ``worker.resume()``.
    """

    def __init__(self) -> None:
        self._paused = asyncio.Event()
        self._paused.set()  # Not paused by default
        self._running = False
        self._task: Optional[asyncio.Task] = None  # type: ignore[type-arg]

    # ------------------------------------------------------------------
    # Control API
    # ------------------------------------------------------------------

    def start(self) -> None:
        """Schedule the worker as an asyncio background task."""
        if self._task is not None and not self._task.done():
            logger.info("EnrichmentWorker already running")
            return
        self._running = True
        self._paused.set()
        self._task = asyncio.create_task(self.run(), name="enrichment_worker")
        logger.info("EnrichmentWorker started")

    def pause(self) -> None:
        """Pause processing after the current item finishes."""
        self._paused.clear()
        logger.info("EnrichmentWorker paused")

    def resume(self) -> None:
        """Resume a paused worker."""
        self._paused.set()
        logger.info("EnrichmentWorker resumed")

    def is_paused(self) -> bool:
        return not self._paused.is_set()

    def is_running(self) -> bool:
        return self._task is not None and not self._task.done()

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------

    async def run(self) -> None:
        """Main enrichment loop — runs until cancelled or ``_running`` is False."""
        from backend.db import get_db_connection  # noqa: PLC0415

        logger.info("EnrichmentWorker loop started")
        self._running = True

        while self._running:
            # Respect pause
            await self._paused.wait()

            conn = get_db_connection()
            try:
                # Pull a batch of pending items
                rows = conn.execute("""
                    SELECT item_key, artist, title, album
                    FROM enrichment_queue
                    WHERE status = 'pending' AND attempts < ?
                    ORDER BY created_at ASC
                    LIMIT ?
                """, (MAX_ATTEMPTS, BATCH_SIZE)).fetchall()

                if not rows:
                    # Nothing to do — sleep then re-check
                    logger.debug("Enrichment queue empty, sleeping %ds", BATCH_PAUSE_SECONDS)
                    conn.close()
                    await asyncio.sleep(BATCH_PAUSE_SECONDS)
                    continue

                logger.info("EnrichmentWorker: processing batch of %d items", len(rows))

                for row in rows:
                    # Respect pause between items too
                    await self._paused.wait()
                    if not self._running:
                        break

                    item_key = row["item_key"]
                    artist = row["artist"]
                    title = row["title"]

                    # Mark as processing
                    conn.execute("""
                        UPDATE enrichment_queue
                        SET status = 'processing', attempts = attempts + 1
                        WHERE item_key = ?
                    """, (item_key,))
                    conn.commit()

                    success = await enrich_one(item_key, artist, title, conn)

                    if not success:
                        # Check attempts; mark failed if exceeded
                        attempts_row = conn.execute(
                            "SELECT attempts FROM enrichment_queue WHERE item_key = ?",
                            (item_key,)
                        ).fetchone()
                        attempts = attempts_row["attempts"] if attempts_row else MAX_ATTEMPTS

                        if attempts >= MAX_ATTEMPTS:
                            now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
                            conn.execute("""
                                UPDATE enrichment_queue
                                SET status = 'failed', error_message = 'max attempts exceeded',
                                    processed_at = ?
                                WHERE item_key = ?
                            """, (now, item_key))
                        else:
                            conn.execute("""
                                UPDATE enrichment_queue
                                SET status = 'pending'
                                WHERE item_key = ?
                            """, (item_key,))
                        conn.commit()

                    await asyncio.sleep(ITEM_SLEEP_SECONDS)

            except asyncio.CancelledError:
                logger.info("EnrichmentWorker task cancelled")
                break
            except Exception as exc:
                logger.error("EnrichmentWorker unexpected error: %s", exc, exc_info=True)
                await asyncio.sleep(10)
            finally:
                try:
                    conn.close()
                except Exception:
                    pass

        logger.info("EnrichmentWorker loop exited")


# ===========================================================================
# Module-level singleton
# ===========================================================================

_worker: EnrichmentWorker | None = None


def get_worker() -> EnrichmentWorker:
    """Return (or create) the module-level EnrichmentWorker."""
    global _worker
    if _worker is None:
        _worker = EnrichmentWorker()
    return _worker
