"""Application startup and shutdown helpers.

Split out from main.py lifespan so the lifespan function stays short and readable.
Three entry points:
    - init_clients(app)          — initialise all service clients
    - start_background_tasks(app) — launch all background asyncio tasks
    - shutdown(app)               — cancel tasks and close resources
"""

from __future__ import annotations

import asyncio
import logging
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from fastapi import FastAPI

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Helper: task done callback
# ---------------------------------------------------------------------------

def _make_task_done_callback(name: str):
    """Return a callback that logs if a background task exits unexpectedly."""
    def _callback(task: asyncio.Task) -> None:
        if task.cancelled():
            return
        exc = task.exception()
        if exc:
            logger.error("Background task '%s' raised an exception: %s", name, exc, exc_info=exc)
        else:
            logger.warning("Background task '%s' exited unexpectedly", name)
    return _callback


# ---------------------------------------------------------------------------
# Client initialisation
# ---------------------------------------------------------------------------

async def init_clients(app: FastAPI) -> None:
    """Initialise all external service clients and store them on app.state."""
    from backend import library_cache  # noqa: PLC0415
    from backend.config import (  # noqa: PLC0415
        get_acoustid_config,
        get_config,
        get_lastfm_config,
        get_listenbrainz_config,
        get_notifications_config,
        get_qobuz_config,
    )
    from backend.llm_client import init_llm_client  # noqa: PLC0415
    from backend.qobuz_api import init_qobuz_api_client  # noqa: PLC0415
    from backend.roon_client import init_roon_client  # noqa: PLC0415

    config = get_config()

    # Notification EventBus
    from backend.notifications import configure_from_settings, event_bus  # noqa: PLC0415
    configure_from_settings(get_notifications_config())
    event_bus.set_event_loop(asyncio.get_event_loop())

    # Roon client
    if config.roon.host:
        init_roon_client(
            config.roon.host,
            config.roon.port,
            config.roon.core_id,
            config.roon.token,
        )

    # LLM client (local providers don't need an API key)
    if config.llm.api_key or config.llm.provider in ("ollama", "custom"):
        init_llm_client(config.llm)

    # Qobuz direct API (playlist save — independent of Roon)
    qobuz_cfg = get_qobuz_config()
    if qobuz_cfg["email"] and qobuz_cfg["password"]:
        init_qobuz_api_client(qobuz_cfg["email"], qobuz_cfg["password"])

    # ListenBrainz
    lb_cfg = get_listenbrainz_config()
    if lb_cfg["token"]:
        from backend.listenbrainz_client import init_lb_client  # noqa: PLC0415
        lb_client = init_lb_client(lb_cfg["token"], lb_cfg["username"])
        app.state.lb_client = lb_client
        logger.info("ListenBrainz client initialized for user: %s", lb_cfg["username"])
        from backend.listenbrainz_sync import init_sync_instance  # noqa: PLC0415
        init_sync_instance(lb_client)
    else:
        app.state.lb_client = None

    # Last.fm
    lf_cfg = get_lastfm_config()
    if lf_cfg["api_key"] and lf_cfg["api_secret"]:
        from backend.lastfm_client import init_lf_client  # noqa: PLC0415
        lf_client = init_lf_client(
            api_key=lf_cfg["api_key"],
            api_secret=lf_cfg["api_secret"],
            session_key=lf_cfg["session_key"],
            username=lf_cfg["username"],
        )
        app.state.lf_client = lf_client
        logger.info("Last.fm client initialized (user: %s)", lf_cfg["username"] or "not set")
        from backend.lastfm_sync import init_lf_sync_instance  # noqa: PLC0415
        init_lf_sync_instance(lf_client)
    else:
        app.state.lf_client = None

    # AcoustID
    acoustid_cfg = get_acoustid_config()
    if acoustid_cfg["enabled"]:
        from backend.acoustid_client import init_verifier  # noqa: PLC0415
        init_verifier(acoustid_cfg["api_key"])
        logger.info(
            "AcoustID verifier initialised (auto_verify_qobuz=%s)",
            acoustid_cfg["auto_verify_qobuz"],
        )

    # DB schema — initialise early so migration flag is set
    library_cache.ensure_db_initialized().close()

    # Self-heal corrupt SQLite indexes from interrupted writes (uvicorn reload,
    # container kill, etc.). Also resets stuck 'processing'/'analyzing' rows
    # so workers don't leave orphan items every restart.
    from backend.db import get_db_connection, repair_corrupt_indexes  # noqa: PLC0415

    _repair_conn = get_db_connection()
    try:
        repaired = repair_corrupt_indexes(_repair_conn)
        if repaired:
            logger.info("Auto-repaired indexes on: %s", repaired)
        # Reset any rows orphaned mid-write by the previous shutdown.
        for table, busy_state in [
            ("enrichment_queue", "processing"),
            ("audio_features_queue", "analyzing"),
        ]:
            try:
                n = _repair_conn.execute(
                    f"UPDATE {table} SET status='pending' WHERE status=?",
                    (busy_state,),
                ).rowcount
                if n:
                    logger.info("Reset %d orphaned %s rows in %s to 'pending'",
                                n, busy_state, table)
            except Exception as exc:
                logger.debug("Orphan reset on %s skipped: %s", table, exc)

        # NOTE: clap_runs / lyrics_runs / mood_runs reset moved to
        # worker_process.py — the worker owns those batch jobs now, and the
        # main API process must not stomp on 'running' rows mid-run when
        # uvicorn --reload restarts it on every backend file save.

        _repair_conn.commit()
    finally:
        _repair_conn.close()


# ---------------------------------------------------------------------------
# Background task launcher
# ---------------------------------------------------------------------------

async def start_background_tasks(app: FastAPI) -> None:
    """Launch all long-running background asyncio tasks.

    Task references are stored in ``app.state.background_tasks`` so
    :func:`shutdown` can cancel them cleanly.
    """
    from backend import library_cache  # noqa: PLC0415
    from backend.roon_client import get_roon_client  # noqa: PLC0415

    app.state.background_tasks: list[asyncio.Task] = []

    def _add_task(coro, name: str) -> asyncio.Task:
        task = asyncio.create_task(coro, name=name)
        task.add_done_callback(_make_task_done_callback(name))
        app.state.background_tasks.append(task)
        return task

    # Auto-resync after schema migration
    roon_client = get_roon_client()
    if library_cache.needs_resync() and roon_client and roon_client.is_connected():
        logger.info("Schema migration detected — starting automatic library re-sync")

        async def _run_resync() -> None:
            try:
                await asyncio.to_thread(library_cache.sync_library, roon_client)
                from backend.audio_features.song_path import invalidate_song_path_cache  # noqa: PLC0415, I001
                invalidate_song_path_cache()
            except Exception as exc:
                logger.error("Auto-resync failed: %s", exc)

        _add_task(_run_resync(), "auto_resync")

    # Wire event loop for fire-and-forget LB scrobbles from monitor thread
    from backend.roon_intelligence import set_monitor_event_loop  # noqa: PLC0415
    set_monitor_event_loop(asyncio.get_event_loop())

    # Roon listening history monitor
    if roon_client is not None:
        try:
            roon_client.start_listening_monitor()
            logger.info("Listening history monitor started")
        except Exception as exc:
            logger.warning("Could not start listening monitor: %s", exc)

    # ListenBrainz background sync (every 6 hours)
    if getattr(app.state, "lb_client", None) is not None:
        async def _lb_sync_loop() -> None:
            from backend.listenbrainz_sync import get_sync_instance  # noqa: PLC0415
            await asyncio.sleep(30)
            while True:
                try:
                    sync = get_sync_instance()
                    if sync:
                        await sync.sync_all()
                except Exception as exc:
                    logger.warning("ListenBrainz background sync error: %s", exc)
                await asyncio.sleep(6 * 3600)

        _add_task(_lb_sync_loop(), "lb_sync")
        logger.info("ListenBrainz background sync scheduled (every 6 hours)")

    # Last.fm background sync (every 6 hours)
    if getattr(app.state, "lf_client", None) is not None:
        async def _lf_sync_loop() -> None:
            from backend.lastfm_sync import get_lf_sync_instance  # noqa: PLC0415
            await asyncio.sleep(45)
            while True:
                try:
                    sync = get_lf_sync_instance()
                    if sync:
                        await sync.sync_all()
                except Exception as exc:
                    logger.warning("Last.fm background sync error: %s", exc)
                await asyncio.sleep(6 * 3600)

        _add_task(_lf_sync_loop(), "lf_sync")
        logger.info("Last.fm background sync scheduled (every 6 hours)")

    # Auto-trigger historical scrobble import if configured but never completed,
    # and run a fast genre enrichment pass on any existing imported rows.
    _has_lb  = getattr(app.state, "lb_client", None) is not None
    _has_lf  = getattr(app.state, "lf_client", None) is not None
    if _has_lb or _has_lf:
        async def _auto_scrobble_bootstrap() -> None:
            # Wait for library sync to settle before enriching
            await asyncio.sleep(90)
            from backend.db import get_db_connection as _gdc  # noqa: PLC0415
            from backend.scrobble_import import (  # noqa: PLC0415
                enrich_imported_genres,
                get_import_state,
                start_lastfm_import,
                start_lb_import,
            )
            # Kick off imports for sources that have never completed
            lb = getattr(app.state, "lb_client", None)
            if lb is not None and get_import_state("listenbrainz").get("status") not in ("complete", "running"):
                logger.info("Auto-triggering ListenBrainz history import (never completed)")
                await start_lb_import(lb, from_year=2014)
            lf = getattr(app.state, "lf_client", None)
            if lf is not None and get_import_state("lastfm").get("status") not in ("complete", "running"):
                logger.info("Auto-triggering Last.fm history import (never completed)")
                await start_lastfm_import(lf, from_year=2014)
            # Fast SQL pass: enrich any previously-imported rows still missing genre
            conn = _gdc()
            try:
                n = enrich_imported_genres(conn)
                if n:
                    logger.info("Startup scrobble enrichment: backfilled %d rows", n)
                # If rows still lack genre, resume Last.fm tag enrichment (may have
                # been interrupted by a previous server reload mid-run).
                remaining = conn.execute(
                    "SELECT COUNT(*) FROM listening_history"
                    " WHERE source IN ('lastfm','listenbrainz')"
                    " AND (genre IS NULL OR genre = '')"
                ).fetchone()[0]
            finally:
                conn.close()
            if remaining and lf is not None:
                from backend.scrobble_import import (  # noqa: PLC0415
                    get_tag_enrich_state,
                    start_lastfm_tag_enrich,
                )
                if get_tag_enrich_state().get("status") != "running":
                    logger.info(
                        "Auto-resuming Last.fm tag enrichment (%d rows still missing genre)",
                        remaining,
                    )
                    await start_lastfm_tag_enrich(lf)

        _add_task(_auto_scrobble_bootstrap(), "auto_scrobble_bootstrap")

    # Watchlist background scan (interval configurable via env var)
    from backend.config import get_watchlist_scan_interval_seconds  # noqa: PLC0415
    _watchlist_interval = get_watchlist_scan_interval_seconds()

    async def _watchlist_scan_loop() -> None:
        from backend.watchlist import scan_all_watched  # noqa: PLC0415
        await asyncio.sleep(60)
        while True:
            try:
                await scan_all_watched()
            except Exception as exc:
                logger.warning("Watchlist background scan error: %s", exc)
            await asyncio.sleep(_watchlist_interval)

    _add_task(_watchlist_scan_loop(), "watchlist_scan")
    logger.info(
        "Watchlist background scan scheduled (every %d hours)",
        _watchlist_interval // 3600,
    )

    # Playlist scheduler
    from backend.scheduler import init_scheduler  # noqa: PLC0415
    init_scheduler()

    import os as _os  # noqa: PLC0415
    _worker_sidecar = _os.getenv("WORKER_SIDECAR", "false").lower() == "true"

    # Metadata enrichment worker
    if _worker_sidecar:
        logger.info("Metadata enrichment worker delegated to sidecar (WORKER_SIDECAR=true)")
    else:
        from backend.db import get_db_connection  # noqa: PLC0415
        from backend.enrichment_worker import get_worker, populate_enrichment_queue  # noqa: PLC0415
        try:
            _enrich_conn = get_db_connection()
            _pending = populate_enrichment_queue(_enrich_conn)
            _enrich_conn.close()
            logger.info("Enrichment queue: %d new items queued", _pending)
        except Exception as exc:
            logger.warning("Could not populate enrichment queue at startup: %s", exc)
        get_worker().start()
        logger.info("Metadata enrichment worker started")

    # Audio features worker (BPM / key / energy) — opt-in via env var.
    from backend.config import (  # noqa: PLC0415
        get_audio_features_enabled,
        get_music_library_path,
    )
    if get_audio_features_enabled():
        if _worker_sidecar:
            logger.info("Audio features worker delegated to sidecar (WORKER_SIDECAR=true)")
        else:
            try:
                from backend.audio_features.path_resolver import (
                    resolve_paths_for_tracks,  # noqa: PLC0415
                )
                from backend.audio_features.worker import (  # noqa: PLC0415
                    get_features_worker,
                    populate_audio_features_queue,
                )
                music_root = get_music_library_path()

                async def _audio_features_bootstrap() -> None:
                    """Resolve filesystem paths + populate queue on first boot.

                    Runs in a thread because the filesystem walk + tag read can
                    take several minutes on a large library. Worker is started
                    immediately after so it can begin processing as soon as the
                    first rows land in the queue.
                    """
                    from backend.db import get_db_connection as _gdc  # noqa: PLC0415
                    try:
                        def _bootstrap_sync() -> dict:
                            _c = _gdc()
                            try:
                                resolved = resolve_paths_for_tracks(_c, music_root)
                                queued = populate_audio_features_queue(_c)
                                return {**resolved, "queued": queued}
                            finally:
                                _c.close()
                        result = await asyncio.to_thread(_bootstrap_sync)
                        logger.info("Audio features bootstrap complete: %s", result)
                    except Exception as exc:
                        logger.warning("Audio features bootstrap failed: %s", exc)

                _add_task(_audio_features_bootstrap(), "audio_features_bootstrap")
                get_features_worker().start()
                logger.info("Audio features worker started (music_root=%s)", music_root)
            except Exception as exc:
                logger.warning("Could not start audio features worker: %s", exc)
    else:
        logger.info("Audio features disabled (set AUDIO_FEATURES_ENABLED=true to enable)")

    # Automation Engine
    from backend.automation_engine import init_engine  # noqa: PLC0415
    init_engine()

    # Background AI — trickle mode: one batch at a time, always making progress.
    # Pause between batches is short at night (01:00–07:00) for fast catch-up,
    # and longer during the day so Gemma 4 can breathe between requests.
    # All jobs share a global asyncio.Semaphore(1) — no concurrent LLM calls.

    async def _vibe_tagging_loop() -> None:
        import datetime as _dt  # noqa: PLC0415

        from backend.background_ai import (  # noqa: PLC0415
            BATCH_PAUSE,
            DAY_PAUSE,
            NIGHT_END,
            NIGHT_START,
            enrich_vibes_batch,
        )
        from backend.llm_client import is_background_ai_enabled  # noqa: PLC0415
        await asyncio.sleep(30)  # brief startup settle
        while True:
            if is_background_ai_enabled():
                try:
                    await enrich_vibes_batch(max_batches=1)
                except Exception as exc:
                    logger.warning("Vibe tagging batch failed: %s", exc)
            h = _dt.datetime.now().hour
            pause = BATCH_PAUSE if NIGHT_START <= h < NIGHT_END else DAY_PAUSE
            await asyncio.sleep(pause)

    _add_task(_vibe_tagging_loop(), "vibe_tagging_loop")
    logger.info("Vibe tagging running continuously (night: %ds, day: 90s between batches)", 8)

    async def _lyrics_themes_loop() -> None:
        import datetime as _dt  # noqa: PLC0415

        from backend.background_ai import (  # noqa: PLC0415
            LYRICS_DAY_PAUSE,
            LYRICS_PAUSE,
            NIGHT_END,
            NIGHT_START,
            extract_lyrics_themes_batch,
        )
        from backend.llm_client import is_background_ai_enabled  # noqa: PLC0415
        await asyncio.sleep(90)  # start slightly after vibes to stagger first batch
        while True:
            if is_background_ai_enabled():
                try:
                    await extract_lyrics_themes_batch(max_batches=1)
                except Exception as exc:
                    logger.warning("Lyrics themes batch failed: %s", exc)
            h = _dt.datetime.now().hour
            pause = LYRICS_PAUSE if NIGHT_START <= h < NIGHT_END else LYRICS_DAY_PAUSE
            await asyncio.sleep(pause)

    _add_task(_lyrics_themes_loop(), "lyrics_themes_loop")
    logger.info("Lyrics themes running continuously (night: %ds, day: 120s between batches)", 15)

    # Discovery section descriptions — light job, runs at startup then every 24 h
    async def _discovery_descriptions_loop() -> None:
        from backend.background_ai import refresh_discovery_descriptions  # noqa: PLC0415
        from backend.llm_client import is_background_ai_enabled  # noqa: PLC0415
        await asyncio.sleep(60)  # let library + taste profile settle
        while True:
            if is_background_ai_enabled():
                try:
                    await refresh_discovery_descriptions()
                except Exception as exc:
                    logger.warning("Discovery descriptions refresh failed: %s", exc)
            await asyncio.sleep(24 * 3600)

    _add_task(_discovery_descriptions_loop(), "discovery_descriptions_refresh")
    logger.info("Discovery AI descriptions scheduled (first run in 60s, then every 24h)")

    # Template suggestions — light job, runs weekly
    async def _template_suggestions_loop() -> None:
        from backend.background_ai import generate_template_suggestions  # noqa: PLC0415
        from backend.llm_client import is_background_ai_enabled  # noqa: PLC0415
        await asyncio.sleep(300)  # after startup settle + discovery descriptions
        while True:
            if is_background_ai_enabled():
                try:
                    await generate_template_suggestions()
                except Exception as exc:
                    logger.warning("Template suggestions failed: %s", exc)
            await asyncio.sleep(7 * 24 * 3600)  # weekly

    _add_task(_template_suggestions_loop(), "template_suggestions_loop")
    logger.info("Template suggestions scheduled (first run in 5 min, then weekly)")

    # Periodic DB backup (every 4 hours)
    async def _db_backup_loop() -> None:
        import shutil  # noqa: PLC0415

        from backend.db import DB_PATH  # noqa: PLC0415
        while True:
            await asyncio.sleep(4 * 3600)
            try:
                backup = DB_PATH.with_suffix(".db.bak")
                shutil.copy2(str(DB_PATH), str(backup))
                logger.info("DB backup written to %s", backup)
            except Exception as exc:
                logger.warning("DB backup failed: %s", exc)

    _add_task(_db_backup_loop(), "db_backup")

    # LLM response cache: purge expired entries every 6 hours
    async def _llm_cache_purge_loop() -> None:
        from backend import llm_cache  # noqa: PLC0415
        from backend.config import get_llm_cache_ttl_seconds  # noqa: PLC0415

        await asyncio.sleep(300)
        while True:
            try:
                ttl = get_llm_cache_ttl_seconds()
                deleted = llm_cache.purge_expired(ttl)
                if deleted:
                    logger.info("LLM cache: purged %d expired entries", deleted)
            except Exception as exc:
                logger.warning("LLM cache purge failed: %s", exc)
            await asyncio.sleep(6 * 3600)

    _add_task(_llm_cache_purge_loop(), "llm_cache_purge")


# ---------------------------------------------------------------------------
# Graceful shutdown
# ---------------------------------------------------------------------------

async def shutdown(app: FastAPI) -> None:
    """Stop all background tasks and close open resources."""
    import backend.routes.recommend as _recommend_module  # noqa: PLC0415

    # Stop playlist scheduler
    from backend.scheduler import stop_scheduler  # noqa: PLC0415
    stop_scheduler()

    # Stop automation engine
    from backend.automation_engine import stop_engine  # noqa: PLC0415
    stop_engine()

    # Cancel all managed background tasks
    tasks: list[asyncio.Task] = getattr(app.state, "background_tasks", [])
    for task in tasks:
        if not task.done():
            task.cancel()
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)
        logger.info("Cancelled %d background task(s)", len(tasks))

    # Close httpx clients used by the recommendation pipeline
    if _recommend_module._music_research_client is not None:
        await _recommend_module._music_research_client.close()
    if _recommend_module._art_proxy_client is not None:
        await _recommend_module._art_proxy_client.aclose()

    # Close LLM client (Ollama AsyncClient)
    from backend.llm_client import get_llm_client  # noqa: PLC0415
    llm = get_llm_client()
    if llm is not None:
        await llm.close()

    # Flush SQLite WAL to the main DB file before exit — prevents corruption
    # on hard container kills by ensuring the DB is in a consistent state.
    try:
        from backend.db import get_db_connection  # noqa: PLC0415
        _db = get_db_connection()
        _db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        _db.close()
        logger.info("SQLite WAL checkpoint complete")
    except Exception as exc:
        logger.warning("SQLite WAL checkpoint failed: %s", exc)
