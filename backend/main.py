"""FastAPI application for RoonSage."""

import asyncio
import base64
import logging
import secrets
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse, JSONResponse

from backend.config import get_config, get_qobuz_config, get_listenbrainz_config, get_lastfm_config, get_notifications_config
from backend.version import get_version
from backend.roon_client import get_roon_client, init_roon_client
from backend.qobuz_api import init_qobuz_api_client
from backend import library_cache
from backend.llm_client import init_llm_client
from backend.routes import setup, library, generate, recommend, roon, config_routes, results
from backend.routes.qobuz_playlist import router as qobuz_playlist_router
from backend.routes.intelligence import router as intelligence_router
from backend.routes.discovery import router as discovery_router
from backend.routes.templates import router as templates_router
from backend.routes.notifications import router as notifications_router
from backend.routes.watchlist import router as watchlist_router
from backend.routes.scheduler import router as scheduler_router
from backend.routes.enrichment import router as enrichment_router
from backend.routes.automations import router as automations_router
from backend.dependencies import ROONSAGE_PASSWORD
import backend.routes.recommend as _recommend_module

logging.basicConfig(level=logging.INFO)

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize clients on startup."""
    config = get_config()

    # Initialize notification EventBus from saved config
    from backend.notifications import configure_from_settings, event_bus  # noqa: PLC0415
    configure_from_settings(get_notifications_config())
    event_bus.set_event_loop(asyncio.get_event_loop())

    # Initialize Roon client if configured
    if config.roon.host:
        init_roon_client(
            config.roon.host,
            config.roon.port,
            config.roon.core_id,
            config.roon.token,
        )

    # Initialize LLM client if configured
    # Local providers (ollama, custom) don't need an API key
    if config.llm.api_key or config.llm.provider in ("ollama", "custom"):
        init_llm_client(config.llm)

    # Initialize Qobuz direct API client (for playlist save — independent of Roon)
    # app_id and app_secret are auto-extracted from the Qobuz web player.
    qobuz_cfg = get_qobuz_config()
    if qobuz_cfg["email"] and qobuz_cfg["password"]:
        init_qobuz_api_client(
            qobuz_cfg["email"],
            qobuz_cfg["password"],
        )

    # Initialize ListenBrainz client if configured
    lb_cfg = get_listenbrainz_config()
    if lb_cfg["token"]:
        from backend.listenbrainz_client import init_lb_client  # noqa: PLC0415
        lb_client = init_lb_client(lb_cfg["token"], lb_cfg["username"])
        app.state.lb_client = lb_client
        logger.info("ListenBrainz client initialized for user: %s", lb_cfg["username"])
        # Also init the sync instance
        from backend.listenbrainz_sync import init_sync_instance  # noqa: PLC0415
        init_sync_instance(lb_client)
    else:
        app.state.lb_client = None

    # Initialize Last.fm client if configured
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

    # Initialize DB schema early so migration flag is set
    library_cache.ensure_db_initialized().close()

    # Auto-sync if a migration was applied and existing tracks need re-sync
    roon_client = get_roon_client()
    if library_cache.needs_resync() and roon_client and roon_client.is_connected():
        logger.info("Schema migration detected — starting automatic library re-sync")

        async def _run_resync():
            try:
                await asyncio.to_thread(library_cache.sync_library, roon_client)
            except Exception as e:
                logger.error("Auto-resync failed: %s", e)

        asyncio.create_task(_run_resync())

    # Register the event loop for fire-and-forget LB scrobbles from monitor thread
    from backend.roon_intelligence import set_monitor_event_loop  # noqa: PLC0415
    set_monitor_event_loop(asyncio.get_event_loop())

    # Start listening history monitor once Roon is available.
    # We attempt immediately; if Roon is still connecting the monitor will
    # wait internally until is_connected() returns True.
    if roon_client is not None:
        try:
            roon_client.start_listening_monitor()
            logger.info("Listening history monitor started")
        except Exception as exc:
            logger.warning("Could not start listening monitor: %s", exc)

    # Start ListenBrainz background sync (every 6 hours)
    if getattr(app.state, "lb_client", None) is not None:
        async def _lb_sync_loop():
            from backend.listenbrainz_sync import get_sync_instance  # noqa: PLC0415
            await asyncio.sleep(30)  # Small delay so app is fully started
            while True:
                try:
                    sync = get_sync_instance()
                    if sync:
                        await sync.sync_all()
                except Exception as exc:
                    logger.warning("ListenBrainz background sync error: %s", exc)
                await asyncio.sleep(6 * 3600)  # every 6 hours

        asyncio.create_task(_lb_sync_loop())
        logger.info("ListenBrainz background sync scheduled (every 6 hours)")

    # Start Last.fm background sync (every 6 hours)
    if getattr(app.state, "lf_client", None) is not None:
        async def _lf_sync_loop():
            from backend.lastfm_sync import get_lf_sync_instance  # noqa: PLC0415
            await asyncio.sleep(45)  # Small delay so app is fully started
            while True:
                try:
                    sync = get_lf_sync_instance()
                    if sync:
                        await sync.sync_all()
                except Exception as exc:
                    logger.warning("Last.fm background sync error: %s", exc)
                await asyncio.sleep(6 * 3600)  # every 6 hours

        asyncio.create_task(_lf_sync_loop())
        logger.info("Last.fm background sync scheduled (every 6 hours)")

    # Start Watchlist background scan (every 12 hours)
    import os  # noqa: PLC0415
    _watchlist_interval = int(os.environ.get("WATCHLIST_SCAN_INTERVAL_HOURS", "12")) * 3600

    async def _watchlist_scan_loop():
        from backend.watchlist import scan_all_watched  # noqa: PLC0415
        await asyncio.sleep(60)  # Wait 60s after startup before first scan
        while True:
            try:
                await scan_all_watched()
            except Exception as exc:
                logger.warning("Watchlist background scan error: %s", exc)
            await asyncio.sleep(_watchlist_interval)

    asyncio.create_task(_watchlist_scan_loop())
    logger.info(
        "Watchlist background scan scheduled (every %d hours)",
        _watchlist_interval // 3600,
    )

    # Start playlist scheduler
    from backend.scheduler import init_scheduler  # noqa: PLC0415
    init_scheduler()

    # Start metadata enrichment worker (auto-starts if queue has pending items)
    from backend.enrichment_worker import get_worker, populate_enrichment_queue  # noqa: PLC0415
    from backend.db import get_db_connection  # noqa: PLC0415
    try:
        _enrich_conn = get_db_connection()
        _pending = populate_enrichment_queue(_enrich_conn)
        _enrich_conn.close()
        logger.info("Enrichment queue: %d new items queued", _pending)
    except Exception as _enrich_err:
        logger.warning("Could not populate enrichment queue at startup: %s", _enrich_err)

    get_worker().start()
    logger.info("Metadata enrichment worker started")

    # Start Automation Engine
    from backend.automation_engine import init_engine  # noqa: PLC0415
    init_engine()

    yield

    # Shutdown: stop playlist scheduler
    from backend.scheduler import stop_scheduler  # noqa: PLC0415
    stop_scheduler()

    # Shutdown: stop automation engine
    from backend.automation_engine import stop_engine  # noqa: PLC0415
    stop_engine()

    # Shutdown: clean up resources (read from module to get current values, not import-time snapshot)
    if _recommend_module._music_research_client is not None:
        await _recommend_module._music_research_client.close()
    if _recommend_module._art_proxy_client is not None:
        await _recommend_module._art_proxy_client.aclose()


app = FastAPI(
    title="RoonSage",
    description="Roon AI playlist generator powered by LLMs",
    version=get_version(),
    lifespan=lifespan,
)


# =============================================================================
# Optional HTTP Basic Auth middleware
# =============================================================================
# Activated only when ROONSAGE_PASSWORD environment variable is set.
# Exempt routes that must work without auth:
#   - GET /api/health    (Docker health checks)
#   - GET /api/art/*     (album art images used in the UI after login)
#   - GET /api/external-art  (proxied external cover art)

_AUTH_EXEMPT_EXACT = {"/api/health", "/api/external-art"}
_AUTH_EXEMPT_PREFIX = "/api/art/"


@app.middleware("http")
async def optional_basic_auth(request: Request, call_next):
    """Enforce HTTP Basic Auth when ROONSAGE_PASSWORD is configured."""
    if not ROONSAGE_PASSWORD:
        return await call_next(request)

    path = request.url.path
    if path in _AUTH_EXEMPT_EXACT or path.startswith(_AUTH_EXEMPT_PREFIX):
        return await call_next(request)

    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Basic "):
        return JSONResponse(
            status_code=401,
            headers={"WWW-Authenticate": 'Basic realm="RoonSage"'},
            content={"detail": "Authentication required"},
        )

    try:
        decoded = base64.b64decode(auth_header[6:]).decode("utf-8")
        _user, password = decoded.split(":", 1)
    except Exception:
        return JSONResponse(
            status_code=401,
            headers={"WWW-Authenticate": 'Basic realm="RoonSage"'},
            content={"detail": "Invalid credentials"},
        )

    if not secrets.compare_digest(password.encode(), ROONSAGE_PASSWORD.encode()):
        return JSONResponse(
            status_code=401,
            headers={"WWW-Authenticate": 'Basic realm="RoonSage"'},
            content={"detail": "Invalid credentials"},
        )

    return await call_next(request)


# Register all routers
app.include_router(setup.router)
app.include_router(library.router)
app.include_router(generate.router)
app.include_router(recommend.router)
app.include_router(roon.router)
app.include_router(config_routes.router)
app.include_router(results.router)
app.include_router(qobuz_playlist_router)
app.include_router(intelligence_router)
app.include_router(discovery_router)
app.include_router(templates_router)
app.include_router(notifications_router)
app.include_router(watchlist_router)
app.include_router(scheduler_router)
app.include_router(enrichment_router)
app.include_router(automations_router)


# =============================================================================
# Static File Serving
# =============================================================================

# Determine the frontend directory path
# In development: ./frontend relative to repo root
# In Docker: /app/frontend
frontend_path = Path(__file__).parent.parent / "frontend"
if not frontend_path.exists():
    frontend_path = Path("/app/frontend")

# Mount static files if frontend directory exists
if frontend_path.exists():
    app.mount(
        "/static",
        StaticFiles(directory=frontend_path),
        name="static",
    )


@app.get("/")
async def serve_index():
    """Serve the main index.html page with cache-busted asset URLs."""
    index_path = frontend_path / "index.html"
    if index_path.exists():
        html = index_path.read_text()
        v = get_version()
        html = html.replace("/static/style.css", f"/static/style.css?v={v}")
        html = html.replace("/static/app.js", f"/static/app.js?v={v}")
        return HTMLResponse(html, headers={"Cache-Control": "no-cache"})
    return {"message": "RoonSage API is running. Frontend not found."}
