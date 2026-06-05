"""Background worker that analyses queued tracks.

Mirrors the design of ``backend/enrichment_worker.py``:
  - SQLite queue table (``audio_features_queue``) drives the work.
  - ``populate_audio_features_queue()`` is called once at startup.
  - The worker pulls a batch of ``status='pending'`` rows and runs the
    analyser concurrently up to ``CONCURRENCY``.
  - Per-item retries up to ``MAX_ATTEMPTS`` before status is set to ``failed``.
  - Pause / resume via ``asyncio.Event`` so the REST API can stop the worker
    without cancelling the task.

Audio analysis is CPU-heavy (librosa.load + chroma + autocorrelation).
Concurrency is set to 4 — tune down if the host CPU is saturated.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
from datetime import UTC, datetime
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import sqlite3

logger = logging.getLogger(__name__)


BATCH_SIZE = 50
BATCH_PAUSE_SECONDS = 60
MAX_ATTEMPTS = 3
CONCURRENCY = 4

# Set AUDIO_FEATURES_FULL=false to compute only BPM + key (fase 1 mode).
# True (default) computes the full Spotify-style feature vector.
from backend.config import get_audio_features_full  # noqa: E402

AUDIO_FEATURES_FULL: bool = get_audio_features_full()


# ---------------------------------------------------------------------------
# Queue management
# ---------------------------------------------------------------------------


def populate_audio_features_queue(conn: sqlite3.Connection) -> int:
    """Enqueue any resolved tracks that still need analysis.

    Path resolution (in ``path_resolver``) inserts rows with ``file_path``
    and ``status='pending'``; this function is therefore mostly a no-op when
    called after resolve_paths_for_tracks. It also clears stale rows for
    tracks that have disappeared from the library.

    Returns the number of newly-inserted ``pending`` rows.
    """
    # Clean stale queue entries for tracks no longer in the library.
    # LEFT JOIN avoids materialising a temp set of all valid item_keys, which
    # SQLite was doing for the original NOT IN form. Roughly 15-30% faster on
    # 46k-track libraries.
    deleted = conn.execute("""
        DELETE FROM audio_features_queue
        WHERE item_key IN (
            SELECT q.item_key
            FROM audio_features_queue q
            LEFT JOIN tracks t ON t.item_key = q.item_key
            WHERE t.item_key IS NULL
        )
    """).rowcount
    if deleted:
        logger.info(
            "Audio features queue: removed %d stale entries (tracks no longer in library)",
            deleted,
        )

    # Prune by stable_id, not item_key: Roon item_keys change across sessions,
    # so an item_key-based prune would wipe all analysis after a resync. A
    # feature row is only stale if its stable_id is genuinely gone.
    conn.execute("""
        DELETE FROM track_audio_features
        WHERE rowid IN (
            SELECT af.rowid
            FROM track_audio_features af
            LEFT JOIN tracks t ON t.stable_id = af.stable_id
            WHERE af.stable_id IS NOT NULL AND t.stable_id IS NULL
        )
    """)

    # Insert tracks that have a feature row with a file_path but no analysis yet
    # and aren't in the queue at all.
    conn.execute("""
        INSERT INTO audio_features_queue (item_key, file_path, status)
        SELECT af.item_key, af.file_path, 'pending'
        FROM track_audio_features af
        LEFT JOIN audio_features_queue q ON q.item_key = af.item_key
        WHERE q.item_key IS NULL
          AND af.file_path IS NOT NULL
          AND af.bpm IS NULL
    """)
    count = conn.execute("SELECT changes()").fetchone()[0]
    conn.commit()
    if count:
        logger.info("Audio features queue: %d new items queued", count)
    return int(count)


def get_queue_stats(conn: sqlite3.Connection) -> dict[str, int]:
    """Return queue-status counts + analysed-row counts."""
    stats: dict[str, int] = {
        "pending": 0, "processing": 0, "analyzing": 0,
        "complete": 0, "failed": 0, "unresolved": 0,
    }
    for row in conn.execute(
        "SELECT status, COUNT(*) AS cnt FROM audio_features_queue GROUP BY status"
    ).fetchall():
        stats[row["status"]] = row["cnt"]

    analysed = conn.execute(
        "SELECT COUNT(*) FROM track_audio_features WHERE bpm IS NOT NULL"
    ).fetchone()[0]
    stats["analysed_total"] = int(analysed)
    return stats


# ---------------------------------------------------------------------------
# Per-item analysis
# ---------------------------------------------------------------------------


async def analyze_one(
    item_key: str,
    file_path: str,
    conn: sqlite3.Connection,
) -> bool:
    """Analyse a single track and persist the result. Returns True on success."""
    from backend.audio_features import analyzer  # noqa: PLC0415

    if not file_path or not os.path.exists(file_path):
        conn.execute(
            "UPDATE audio_features_queue SET status='failed', error_message=?"
            " WHERE item_key=?",
            ("file_not_found", item_key),
        )
        conn.commit()
        return False

    try:
        features = await analyzer.analyze_track(file_path, full=AUDIO_FEATURES_FULL)
    except Exception as exc:
        logger.warning("Analysis failed for %s (%s): %s", item_key, file_path, exc)
        return False

    now = datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S")
    try:
        conn.execute("""
            UPDATE track_audio_features SET
                bpm              = :bpm,
                bpm_confidence   = :bpm_confidence,
                key_root         = :key_root,
                key_mode         = :key_mode,
                camelot          = :camelot,
                energy           = :energy,
                danceability     = :danceability,
                valence          = :valence,
                acousticness     = :acousticness,
                instrumentalness = :instrumentalness,
                loudness_lufs    = :loudness_lufs,
                analyzed_at      = :now,
                analysis_version = :version,
                error_message    = NULL
            WHERE item_key = :item_key
        """, {
            "item_key": item_key,
            "bpm": features.get("bpm"),
            "bpm_confidence": features.get("bpm_confidence"),
            "key_root": features.get("key_root"),
            "key_mode": features.get("key_mode"),
            "camelot": features.get("camelot"),
            "energy": features.get("energy"),
            "danceability": features.get("danceability"),
            "valence": features.get("valence"),
            "acousticness": features.get("acousticness"),
            "instrumentalness": features.get("instrumentalness"),
            "loudness_lufs": features.get("loudness_lufs"),
            "now": now,
            "version": 2 if AUDIO_FEATURES_FULL else 1,
        })
        conn.execute("""
            UPDATE audio_features_queue
            SET status='complete', processed_at=?, error_message=NULL
            WHERE item_key=?
        """, (now, item_key))
        conn.commit()
        return True
    except Exception as exc:
        logger.error("DB write failed for audio features of %s: %s", item_key, exc)
        conn.rollback()
        return False


# ---------------------------------------------------------------------------
# Worker class
# ---------------------------------------------------------------------------


class AudioFeaturesWorker:
    """Background task that analyses queued tracks. See module docstring."""

    def __init__(self) -> None:
        self._paused = asyncio.Event()
        self._paused.set()
        self._running = False
        self._task: asyncio.Task | None = None

    def start(self) -> None:
        if self._task is not None and not self._task.done():
            logger.info("AudioFeaturesWorker already running")
            return
        self._running = True
        self._paused.set()
        self._task = asyncio.create_task(self.run(), name="audio_features_worker")
        logger.info("AudioFeaturesWorker started")

    def pause(self) -> None:
        self._paused.clear()
        logger.info("AudioFeaturesWorker paused")

    def resume(self) -> None:
        self._paused.set()
        logger.info("AudioFeaturesWorker resumed")

    def is_paused(self) -> bool:
        return not self._paused.is_set()

    def is_running(self) -> bool:
        return self._task is not None and not self._task.done()

    # -- per-item bookkeeping ------------------------------------------------

    async def _process_one(self, row: sqlite3.Row) -> None:
        from backend.db import get_db_connection  # noqa: PLC0415
        from backend.event_bus import CH_AUDIO_FEATURES, publish  # noqa: PLC0415

        item_key = row["item_key"]
        file_path = row["file_path"]

        publish(
            CH_AUDIO_FEATURES,
            {"type": "item_start", "item_key": item_key, "file_path": file_path},
        )

        conn = get_db_connection()
        try:
            conn.execute("""
                UPDATE audio_features_queue
                SET status='analyzing', attempts=attempts+1
                WHERE item_key=?
            """, (item_key,))
            conn.commit()

            success = await analyze_one(item_key, file_path, conn)
            publish(
                CH_AUDIO_FEATURES,
                {"type": "item_complete", "item_key": item_key, "success": success},
            )

            if not success:
                row_a = conn.execute(
                    "SELECT attempts FROM audio_features_queue WHERE item_key=?",
                    (item_key,),
                ).fetchone()
                attempts = row_a["attempts"] if row_a else MAX_ATTEMPTS
                now = datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S")
                if attempts >= MAX_ATTEMPTS:
                    conn.execute("""
                        UPDATE audio_features_queue
                        SET status='failed', error_message='max attempts exceeded',
                            processed_at=?
                        WHERE item_key=?
                    """, (now, item_key))
                else:
                    conn.execute(
                        "UPDATE audio_features_queue SET status='pending' WHERE item_key=?",
                        (item_key,),
                    )
                conn.commit()
        except Exception as exc:
            logger.error("Error analysing %s: %s", item_key, exc)
            with contextlib.suppress(Exception):
                conn.execute(
                    "UPDATE audio_features_queue SET status='pending' WHERE item_key=?",
                    (item_key,),
                )
                conn.commit()
        finally:
            with contextlib.suppress(Exception):
                conn.close()

    # -- main loop -----------------------------------------------------------

    async def run(self) -> None:
        from backend.db import get_db_connection  # noqa: PLC0415

        logger.info(
            "AudioFeaturesWorker loop started (full=%s, concurrency=%d)",
            AUDIO_FEATURES_FULL, CONCURRENCY,
        )
        self._running = True

        while self._running:
            await self._paused.wait()

            conn = get_db_connection()
            try:
                rows = conn.execute("""
                    SELECT item_key, file_path
                    FROM audio_features_queue
                    WHERE status='pending' AND attempts < ?
                      AND file_path IS NOT NULL
                    ORDER BY created_at ASC
                    LIMIT ?
                """, (MAX_ATTEMPTS, BATCH_SIZE)).fetchall()
            except Exception as exc:
                logger.error("AudioFeaturesWorker DB query failed: %s", exc)
                rows = []
            finally:
                conn.close()

            if not rows:
                await asyncio.sleep(BATCH_PAUSE_SECONDS)
                continue

            logger.info("AudioFeaturesWorker: batch of %d items", len(rows))

            try:
                sem = asyncio.Semaphore(CONCURRENCY)

                async def _bounded(row: sqlite3.Row, _sem: asyncio.Semaphore = sem) -> None:
                    async with _sem:
                        await self._paused.wait()
                        if self._running:
                            await self._process_one(row)

                results = await asyncio.gather(
                    *[asyncio.create_task(_bounded(r)) for r in rows],
                    return_exceptions=True,
                )
                for i, res in enumerate(results):
                    if isinstance(res, Exception) and not isinstance(res, asyncio.CancelledError):
                        logger.error("Unhandled error for %s: %s", rows[i]["item_key"], res)

                # WebSocket progress notification (mirror of enrichment worker).
                try:
                    from backend.db import get_db_connection as _gdc  # noqa: PLC0415
                    from backend.event_bus import CH_AUDIO_FEATURES, publish  # noqa: PLC0415
                    _c = _gdc()
                    try:
                        _stats = get_queue_stats(_c)
                    finally:
                        _c.close()
                    publish(
                        CH_AUDIO_FEATURES,
                        {
                            "type": "batch_complete",
                            "batch_size": len(rows),
                            "pending": _stats.get("pending", 0),
                            "analyzing": _stats.get("analyzing", 0),
                            "complete": _stats.get("complete", 0),
                            "failed": _stats.get("failed", 0),
                        },
                    )
                except Exception:
                    pass
            except asyncio.CancelledError:
                logger.info("AudioFeaturesWorker task cancelled")
                break
            except Exception as exc:
                logger.error("AudioFeaturesWorker unexpected error: %s", exc, exc_info=True)
                await asyncio.sleep(10)
                continue

        logger.info("AudioFeaturesWorker loop exited")


# ---------------------------------------------------------------------------
# Module-level singleton
# ---------------------------------------------------------------------------

_worker: AudioFeaturesWorker | None = None


def get_features_worker() -> AudioFeaturesWorker:
    global _worker
    if _worker is None:
        _worker = AudioFeaturesWorker()
    return _worker
