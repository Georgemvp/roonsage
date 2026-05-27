"""Standalone worker process for RoonSage.

Runs CPU-intensive background jobs (audio-feature analysis, metadata
enrichment) in a separate OS process so the FastAPI event loop stays
responsive.

Usage (Docker Compose — see docker-compose.yml):
    docker compose --profile worker up -d

Standalone:
    python -m backend.worker_process

Set WORKER_SIDECAR=true on the main service so FastAPI skips these workers.
"""

from __future__ import annotations

import asyncio
import logging
import os
import signal
import sys

logger = logging.getLogger(__name__)


def _reset_orphaned_rows() -> None:
    """Reset queue rows left mid-flight by the previous run."""
    from backend.db import get_db_connection  # noqa: PLC0415

    conn = get_db_connection()
    try:
        for table, busy_state in [
            ("enrichment_queue", "processing"),
            ("audio_features_queue", "analyzing"),
        ]:
            try:
                n = conn.execute(
                    f"UPDATE {table} SET status='pending' WHERE status=?",
                    (busy_state,),
                ).rowcount
                if n:
                    logger.info("Reset %d orphaned %s rows in %s", n, busy_state, table)
            except Exception as exc:
                logger.debug("Orphan reset on %s skipped: %s", table, exc)
        conn.commit()
    finally:
        conn.close()


async def main() -> None:
    from backend.config import get_audio_features_enabled, get_music_library_path  # noqa: PLC0415
    from backend.db import get_db_connection  # noqa: PLC0415
    from backend.enrichment_worker import get_worker, populate_enrichment_queue  # noqa: PLC0415
    from backend.library_cache import ensure_db_initialized  # noqa: PLC0415

    logger.info("RoonSage worker process starting (pid=%d)", os.getpid())

    # Ensure DB schema exists (idempotent — main service may have already run it)
    ensure_db_initialized().close()

    _reset_orphaned_rows()

    tasks: list[asyncio.Task] = []

    # Populate enrichment queue and start enrichment worker
    try:
        conn = get_db_connection()
        pending = populate_enrichment_queue(conn)
        conn.close()
        logger.info("Enrichment queue: %d new items", pending)
    except Exception as exc:
        logger.warning("Could not populate enrichment queue: %s", exc)

    enrich_worker = get_worker()
    enrich_worker.start()
    if enrich_worker._task is not None:
        tasks.append(enrich_worker._task)

    # Audio features bootstrap + worker
    if get_audio_features_enabled():
        try:
            from backend.audio_features.path_resolver import (  # noqa: PLC0415
                resolve_paths_for_tracks,
            )
            from backend.audio_features.worker import (  # noqa: PLC0415
                get_features_worker,
                populate_audio_features_queue,
            )

            music_root = get_music_library_path()

            async def _bootstrap() -> None:
                try:
                    def _sync() -> dict:
                        c = get_db_connection()
                        try:
                            resolved = resolve_paths_for_tracks(c, music_root)
                            queued = populate_audio_features_queue(c)
                            return {**resolved, "queued": queued}
                        finally:
                            c.close()
                    result = await asyncio.to_thread(_sync)
                    logger.info("Audio features bootstrap: %s", result)
                except Exception as exc:
                    logger.warning("Audio features bootstrap failed: %s", exc)

            bootstrap_task = asyncio.create_task(_bootstrap(), name="audio_features_bootstrap")
            tasks.append(bootstrap_task)

            af_worker = get_features_worker()
            af_worker.start()
            if af_worker._task is not None:
                tasks.append(af_worker._task)
            logger.info("Audio features worker started (music_root=%s)", music_root)
        except Exception as exc:
            logger.warning("Could not start audio features worker: %s", exc)
    else:
        logger.info("Audio features disabled (AUDIO_FEATURES_ENABLED not set)")

    # Graceful shutdown via SIGTERM / SIGINT
    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    def _handle_signal() -> None:
        logger.info("Shutdown signal received — stopping workers")
        stop_event.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _handle_signal)

    logger.info("Worker process ready")
    await stop_event.wait()

    live = [t for t in tasks if not t.done()]
    for t in live:
        t.cancel()
    if live:
        await asyncio.gather(*live, return_exceptions=True)

    # Flush WAL so the DB is consistent on disk
    try:
        from backend.db import get_db_connection as _gdc  # noqa: PLC0415
        _c = _gdc()
        _c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        _c.close()
    except Exception as exc:
        logger.warning("WAL checkpoint failed: %s", exc)

    logger.info("Worker process stopped")


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        stream=sys.stdout,
    )
    asyncio.run(main())
