"""Background enrichment worker for RoonSage Metadata Enrichment Pipeline (v10.0).

Reads tracks from ``enrichment_queue``, fetches metadata from MusicBrainz
(always) and Last.fm (when configured), then writes results to
``track_metadata_ext``.

Rate limits (per MusicBrainz / Last.fm policy):
  MusicBrainz : 1 req/s  — enforced by musicbrainz_client._mb_semaphore
  Last.fm      : 5 req/s  — enforced by a per-worker semaphore below

Design notes:
  - Up to CONCURRENCY items are processed concurrently (asyncio tasks).
    Each task opens its own SQLite connection to avoid write conflicts.
  - MusicBrainz and Last.fm lookups run in parallel (asyncio.gather) so
    LF latency is hidden inside the mandatory MB 1 s rate-limit sleep.
  - The MusicBrainz semaphore (1 slot, timestamp-based sleep) is the
    global throughput bottleneck — ~0.5 tracks/s per MB-search+tags pair.
  - On failure the item's ``attempts`` counter is incremented; after
    MAX_ATTEMPTS the item is marked ``failed`` and skipped permanently.
  - A pause/resume mechanism uses asyncio.Event so the REST API can
    stop the worker without cancelling the asyncio task.
"""

import asyncio
import contextlib
import json
import logging
import sqlite3
from datetime import UTC, datetime

logger = logging.getLogger(__name__)

# ------------------------------------------------------------------
# Configuration constants
# ------------------------------------------------------------------

BATCH_SIZE = 100          # Max pending items to pull per batch
BATCH_PAUSE_SECONDS = 60  # Sleep between batches when no work is left
MAX_ATTEMPTS = 3          # Retry failed items up to this many times
CONCURRENCY = 5           # Max items processed concurrently within a batch

# Last.fm rate: 5 req/s
_lf_semaphore = asyncio.Semaphore(5)
_LF_SLEEP = 0.21  # seconds after releasing the LF semaphore

# In-memory cache for batch deduplication: (artist, title) → enrichment results
_batch_cache: dict[tuple[str, str], tuple] = {}
BATCH_CACHE_MAX = 2000


# ===========================================================================
# Queue management helpers
# ===========================================================================


def populate_enrichment_queue(conn: sqlite3.Connection) -> int:
    """Insert un-enriched tracks into ``enrichment_queue``.

    Skips tracks that already have a row in ``track_metadata_ext``.
    INSERT OR IGNORE prevents duplicates, so this is safe to call at any time.
    Also removes stale queue entries for tracks no longer in the library.

    Returns the number of newly inserted rows.
    """
    # Remove queue entries for tracks that no longer exist in the library
    deleted = conn.execute("""
        DELETE FROM enrichment_queue
        WHERE item_key NOT IN (SELECT item_key FROM tracks)
    """).rowcount
    if deleted:
        logger.info("Enrichment queue: removed %d stale entries (tracks no longer in library)", deleted)

    # Also clean up track_metadata_ext for removed tracks
    conn.execute("""
        DELETE FROM track_metadata_ext
        WHERE item_key NOT IN (SELECT item_key FROM tracks)
    """)

    conn.commit()

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

    Tries the full artist string first, then falls back to the primary artist
    (text before the first comma) since Roon includes all performers in the
    artist field but Last.fm only indexes the main artist.
    Also retries with parenthetical suffixes stripped from the title
    (e.g. "(Album Version)", "(Remastered 2011)", "(Live)").

    Returns ([], None, None) when Last.fm is not configured or the call fails.
    """
    import re  # noqa: PLC0415

    from backend.lastfm_client import get_lf_client  # noqa: PLC0415

    lf_client = get_lf_client()
    if lf_client is None or not lf_client.is_configured():
        return [], None, None

    # Skip Last.fm lookup for classical/orchestral tracks — they almost never match
    # because Last.fm indexes by composer, not performer
    classical_indicators = [
        'orchestra', 'philharmonic', 'quartet', 'symphony', 'chamber',
        'ensemble', 'staatskapelle', 'philharmoniker',
    ]
    if any(indicator in artist.lower() for indicator in classical_indicators):
        return [], None, None

    # Clean Roon-specific title noise before querying Last.fm
    clean_title = title
    # Strip Roon's " : " work separator (e.g. "5 Minuets, D. 89 : Schubert: …" → "5 Minuets, D. 89")
    if ' : ' in clean_title:
        clean_title = clean_title.split(' : ')[0].strip()
    # Strip leading track numbers (e.g. "04 Learning to Fly" → "Learning to Fly")
    clean_title = re.sub(r'^(\d{1,3})\s+', '', clean_title)
    # Strip leading Unicode/fullwidth characters before latin text
    clean_title = re.sub(r'^[^\x00-\x7F]+\s*', '', clean_title).strip()
    # Use cleaned title for lookups
    title = clean_title if clean_title else title

    # Try full artist string first
    async with _lf_semaphore:
        track_info = await lf_client.get_track_info(artist, title)
        await asyncio.sleep(_LF_SLEEP)

    # Fallback: try primary artist only (before first comma)
    if not track_info and "," in artist:
        primary_artist = artist.split(",")[0].strip()
        async with _lf_semaphore:
            track_info = await lf_client.get_track_info(primary_artist, title)
            await asyncio.sleep(_LF_SLEEP)

    # Also try stripping parenthetical suffixes from title like "(Album Version)", "(Remastered 2011)", "(Live)"
    if not track_info:
        paren_clean = re.sub(r"\s*[\(\[].*?[\)\]]$", "", title).strip()
        if paren_clean != title:
            search_artist = artist.split(",")[0].strip() if "," in artist else artist
            async with _lf_semaphore:
                track_info = await lf_client.get_track_info(search_artist, paren_clean)
                await asyncio.sleep(_LF_SLEEP)

    # Last resort: get artist-level tags if track lookup failed entirely
    if not track_info:
        search_artist = artist.split(",")[0].strip() if "," in artist else artist
        try:
            async with _lf_semaphore:
                artist_tags_data = await lf_client._get({
                    **lf_client._base_params(),
                    "method": "artist.getTopTags",
                    "artist": search_artist,
                    "autocorrect": "1",
                })
                await asyncio.sleep(_LF_SLEEP)
            if artist_tags_data:
                tags = artist_tags_data.get("toptags", {}).get("tag", [])
                if tags:
                    raw_tags = [t.get("name", "").strip() for t in tags[:10] if t.get("name")]
                    return raw_tags, None, None
        except Exception:
            pass
        return [], None, None

    raw_tags: list[str] = []
    toptags = track_info.get("toptags", {})
    for tag in toptags.get("tag", []):
        name = tag.get("name", "").strip()
        if name:
            raw_tags.append(name)

    listeners: int | None = None
    playcount: int | None = None
    with contextlib.suppress(ValueError, TypeError):
        listeners = int(track_info.get("listeners", 0)) or None
    with contextlib.suppress(ValueError, TypeError):
        playcount = int(track_info.get("playcount", 0)) or None

    return raw_tags, listeners, playcount


async def enrich_one(
    item_key: str,
    artist: str,
    title: str,
    conn: sqlite3.Connection,
) -> bool:
    """Enrich a single track.  Returns True on success, False on failure."""
    import re as _re  # noqa: PLC0415

    # Build cache key from primary artist + cleaned title for batch deduplication
    primary = artist.split(",")[0].strip().lower() if artist else ""
    clean = _re.sub(r'\s*[\(\[].*?[\)\]]\s*$', '', title).strip().lower() if title else ""
    cache_key = (primary, clean)

    if cache_key in _batch_cache:
        cached = _batch_cache[cache_key]
        mbid, mb_tags, mb_release_date, mb_country, lf_tags, lf_listeners, lf_playcount = cached
    else:
        from backend.musicbrainz_client import get_mb_client  # noqa: PLC0415

        mb_client = get_mb_client()
        # Run MB and LF lookups in parallel — LF finishes inside MB's rate-limit sleep.
        mb_result, lf_result = await asyncio.gather(
            mb_client.lookup_recording(artist, title),
            _fetch_lastfm(artist, title),
            return_exceptions=True,
        )

        if isinstance(mb_result, Exception):
            logger.warning("MB lookup failed for %s - %s: %s", artist, title, mb_result)
            mbid, mb_tags, mb_release_date, mb_country = None, [], None, None
        else:
            mbid, mb_tags, mb_release_date, mb_country = mb_result

        if isinstance(lf_result, Exception):
            logger.warning("LF lookup failed for %s - %s: %s", artist, title, lf_result)
            lf_tags, lf_listeners, lf_playcount = [], None, None
        else:
            lf_tags, lf_listeners, lf_playcount = lf_result

        # Cache the result for deduplication within the current batch
        if len(_batch_cache) < BATCH_CACHE_MAX:
            _batch_cache[cache_key] = (
                mbid, mb_tags, mb_release_date, mb_country,
                lf_tags, lf_listeners, lf_playcount,
            )

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

    now = datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S")
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

        # Backfill year to tracks table from mb_release_date
        if mb_release_date:
            try:
                year = int(mb_release_date[:4])
                if 1900 <= year <= 2030:
                    conn.execute(
                        "UPDATE tracks SET year = ? WHERE item_key = ? AND (year IS NULL OR year = 0)",
                        (year, item_key),
                    )
                    conn.commit()
            except (ValueError, TypeError):
                pass

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
        self._task: asyncio.Task | None = None  # type: ignore[type-arg]

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
    # Per-item processing (concurrent tasks)
    # ------------------------------------------------------------------

    async def _process_one(self, row: sqlite3.Row) -> None:
        """Enrich a single queue item using its own DB connection."""
        from backend.db import get_db_connection  # noqa: PLC0415

        item_key = row["item_key"]
        artist = row["artist"]
        title = row["title"]

        conn = get_db_connection()
        try:
            conn.execute("""
                UPDATE enrichment_queue
                SET status = 'processing', attempts = attempts + 1
                WHERE item_key = ?
            """, (item_key,))
            conn.commit()

            success = await enrich_one(item_key, artist, title, conn)

            if not success:
                attempts_row = conn.execute(
                    "SELECT attempts FROM enrichment_queue WHERE item_key = ?",
                    (item_key,),
                ).fetchone()
                attempts = attempts_row["attempts"] if attempts_row else MAX_ATTEMPTS
                now = datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S")
                if attempts >= MAX_ATTEMPTS:
                    conn.execute("""
                        UPDATE enrichment_queue
                        SET status = 'failed', error_message = 'max attempts exceeded',
                            processed_at = ?
                        WHERE item_key = ?
                    """, (now, item_key))
                else:
                    conn.execute(
                        "UPDATE enrichment_queue SET status = 'pending' WHERE item_key = ?",
                        (item_key,),
                    )
                conn.commit()
        except Exception as exc:
            logger.error("Error processing %s: %s", item_key, exc)
            with contextlib.suppress(Exception):
                conn.execute(
                    "UPDATE enrichment_queue SET status = 'pending' WHERE item_key = ?",
                    (item_key,),
                )
                conn.commit()
        finally:
            with contextlib.suppress(Exception):
                conn.close()

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

            # Pull a batch of pending items (short-lived connection for SELECT only)
            conn = get_db_connection()
            try:
                rows = conn.execute("""
                    SELECT item_key, artist, title, album
                    FROM enrichment_queue
                    WHERE status = 'pending' AND attempts < ?
                    ORDER BY CASE
                        WHEN artist LIKE '%Orchestra%' OR artist LIKE '%Philharmonic%'
                          OR artist LIKE '%Quartet%'   OR artist LIKE '%Symphony%'
                        THEN 2 ELSE 1
                    END, created_at ASC
                    LIMIT ?
                """, (MAX_ATTEMPTS, BATCH_SIZE)).fetchall()
            except Exception as exc:
                logger.error("EnrichmentWorker DB query failed: %s", exc)
                rows = []
            finally:
                conn.close()

            if not rows:
                logger.debug("Enrichment queue empty, sleeping %ds", BATCH_PAUSE_SECONDS)
                await asyncio.sleep(BATCH_PAUSE_SECONDS)
                continue

            logger.info(
                "EnrichmentWorker: processing batch of %d items (concurrency=%d)",
                len(rows), CONCURRENCY,
            )
            _batch_cache.clear()

            try:
                # Launch up to CONCURRENCY items concurrently; each task owns its DB conn.
                sem = asyncio.Semaphore(CONCURRENCY)

                async def _bounded(row: sqlite3.Row, _sem: asyncio.Semaphore = sem) -> None:
                    async with _sem:
                        await self._paused.wait()
                        if self._running:
                            await self._process_one(row)

                results = await asyncio.gather(
                    *[asyncio.create_task(_bounded(row)) for row in rows],
                    return_exceptions=True,
                )
                for i, res in enumerate(results):
                    if isinstance(res, Exception) and not isinstance(res, asyncio.CancelledError):
                        logger.error("Unhandled error for %s: %s", rows[i]["item_key"], res)
            except asyncio.CancelledError:
                logger.info("EnrichmentWorker task cancelled")
                break
            except Exception as exc:
                logger.error("EnrichmentWorker unexpected error: %s", exc, exc_info=True)
                await asyncio.sleep(10)
                continue

            # Auto-enrich listening_history after each batch
            try:
                from rapidfuzz import fuzz as _fuzz  # noqa: PLC0415
                enrich_conn = get_db_connection()
                try:
                    hist_rows = enrich_conn.execute("""
                        SELECT lh.id, lh.track_title, lh.artist
                        FROM listening_history lh
                        WHERE (lh.genre IS NULL OR lh.genre = '')
                        AND lh.track_title IS NOT NULL AND lh.track_title != ''
                        AND lh.artist IS NOT NULL AND lh.artist != ''
                        LIMIT 100
                    """).fetchall()
                    for hr in hist_rows:
                        hist_id, h_title, h_artist = hr["id"], hr["track_title"], hr["artist"]
                        candidates = enrich_conn.execute(
                            "SELECT item_key, title, artist, year FROM tracks WHERE artist LIKE ? LIMIT 20",
                            (f"%{h_artist[:20]}%",),
                        ).fetchall()
                        best_key, best_score, best_year = None, 0, None
                        for c in candidates:
                            score = _fuzz.token_sort_ratio(
                                f"{h_artist} {h_title}",
                                f"{c['artist']} {c['title']}",
                            )
                            if score > best_score:
                                best_score, best_key, best_year = score, c["item_key"], c["year"]
                        if best_key and best_score >= 80:
                            genre_rows2 = enrich_conn.execute(
                                "SELECT genre FROM track_genres WHERE track_key = ?",
                                (best_key,),
                            ).fetchall()
                            genre = ", ".join(r[0] for r in genre_rows2)
                            decade = f"{(best_year // 10) * 10}s" if best_year else None
                            enrich_conn.execute(
                                "UPDATE listening_history SET genre=?, year=?, decade=? WHERE id=?",
                                (genre, best_year, decade, hist_id),
                            )
                    enrich_conn.commit()
                finally:
                    enrich_conn.close()
            except Exception as enrich_exc:
                logger.debug("Auto listening_history enrichment: %s", enrich_exc)

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
