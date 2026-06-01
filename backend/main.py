"""FastAPI application for RoonSage."""

import base64
import json as _json
import logging
import secrets
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles

from backend.config import get_cors_origins, get_roonsage_password
from backend.dependencies import limiter
from backend.exceptions import RoonSageError
from backend.routes import config_routes, generate, library, recommend, results, roon, setup
from backend.routes.alchemy import router as alchemy_router
from backend.routes.audio_features import router as audio_features_router
from backend.routes.automations import router as automations_router
from backend.routes.background_ai_routes import router as background_ai_router
from backend.routes.background_tasks import router as background_tasks_router
from backend.routes.circadian import router as circadian_router
from backend.routes.clap_search import router as clap_search_router
from backend.routes.clustering import router as clustering_router
from backend.routes.discovery import router as discovery_router
from backend.routes.dj_sets import router as dj_sets_router
from backend.routes.dj_templates import router as dj_templates_router
from backend.routes.enrichment import router as enrichment_router
from backend.routes.intelligence import router as intelligence_router
from backend.routes.lyrics import router as lyrics_router
from backend.routes.mood import router as mood_router
from backend.routes.notifications import router as notifications_router
from backend.routes.playback_intelligence import router as playback_intelligence_router
from backend.routes.qobuz_playlist import router as qobuz_playlist_router
from backend.routes.scheduler import router as scheduler_router
from backend.routes.song_path import router as song_path_router
from backend.routes.sonic_fingerprint import router as sonic_fingerprint_router
from backend.routes.sonic_radio import router as sonic_radio_router
from backend.routes.templates import router as templates_router
from backend.routes.verify import router as verify_router
from backend.routes.watchlist import router as watchlist_router
from backend.startup import init_clients, shutdown, start_background_tasks
from backend.version import get_version

# =============================================================================
# Structured JSON logging
# =============================================================================

class JSONFormatter(logging.Formatter):
    """Emit each log record as a single JSON line for structured log aggregators."""

    def format(self, record: logging.LogRecord) -> str:
        log_entry: dict = {
            "ts": self.formatTime(record),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        if record.exc_info and record.exc_info[0]:
            log_entry["exception"] = self.formatException(record.exc_info)
        return _json.dumps(log_entry)


def setup_logging() -> None:
    """Configure root logger to emit structured JSON lines to stderr."""
    handler = logging.StreamHandler()
    handler.setFormatter(JSONFormatter())
    logging.root.handlers = [handler]
    logging.root.setLevel(logging.INFO)


setup_logging()

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup and shutdown — delegated to backend.startup for clarity."""
    await init_clients(app)
    await start_background_tasks(app)
    yield
    await shutdown(app)


app = FastAPI(
    title="RoonSage",
    description="Roon AI playlist generator powered by LLMs",
    version=get_version(),
    lifespan=lifespan,
)

# =============================================================================
# slowapi rate limiting
# =============================================================================

from slowapi import _rate_limit_exceeded_handler  # noqa: E402, PLC0415
from slowapi.errors import RateLimitExceeded  # noqa: E402, PLC0415

app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)


@app.exception_handler(RoonSageError)
async def roonsage_exception_handler(request: Request, exc: RoonSageError):
    """Render any RoonSageError as a structured JSON response."""
    logger.warning("RoonSageError: %s (%s)", exc.message, type(exc).__name__)
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": exc.message, "type": type(exc).__name__},
    )

# =============================================================================
# CORS middleware — origins controlled via CORS_ORIGINS env var
# =============================================================================

app.add_middleware(
    CORSMiddleware,
    allow_origins=get_cors_origins(),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# =============================================================================
# Optional HTTP Basic Auth middleware
# =============================================================================
# Activated only when ROONSAGE_PASSWORD environment variable is set.
# Exempt routes that must work without auth:
#   - GET /api/health    (Docker health checks)
#   - GET /api/art/*     (album art images used in the UI after login)
#   - GET /api/external-art  (proxied external cover art)

_AUTH_EXEMPT_EXACT = {
    "/api/health",
    "/api/external-art",
    # PWA assets must load before the user authenticates so the browser can
    # register the service worker and read the manifest.
    "/sw.js",
    "/manifest.json",
}
_AUTH_EXEMPT_PREFIX = "/api/art/"


@app.middleware("http")
async def optional_basic_auth(request: Request, call_next):
    """Enforce HTTP Basic Auth when ROONSAGE_PASSWORD is configured."""
    expected_password = get_roonsage_password()
    if not expected_password:
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

    if not secrets.compare_digest(password.encode(), expected_password.encode()):
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
app.include_router(verify_router)
app.include_router(audio_features_router)
app.include_router(dj_sets_router)
app.include_router(dj_templates_router)
app.include_router(clustering_router)
app.include_router(song_path_router)
app.include_router(alchemy_router)
app.include_router(circadian_router)
app.include_router(clap_search_router)
app.include_router(lyrics_router)
app.include_router(mood_router)
app.include_router(sonic_fingerprint_router)
app.include_router(sonic_radio_router)
app.include_router(playback_intelligence_router)
app.include_router(background_tasks_router)
app.include_router(background_ai_router)


# =============================================================================
# JS module cache-bust middleware
# =============================================================================
# Browser caches ES modules under their original URL, so a new deploy that
# only changes app.js?v=NEW still serves stale copies of ./modules/dj-set.js
# etc. Setting no-cache forces the browser to revalidate on every load; the
# server replies 304 when unchanged, so there is no measurable overhead.

@app.middleware("http")
async def js_no_cache(request: Request, call_next):
    response = await call_next(request)
    path = request.url.path
    if path.startswith("/static/") and path.endswith(".js"):
        response.headers["Cache-Control"] = "no-cache, must-revalidate"
    return response


# =============================================================================
# Long-cache headers for versioned static assets (CSS / SVG / icons)
# =============================================================================
# JS modules use no-cache (above) because ES module URLs aren't version-busted
# by index.html. CSS + SVG assets are loaded with ?v={version} cache-busters
# in serve_index, so it's safe to send immutable headers and cut roundtrips.

@app.middleware("http")
async def static_asset_cache(request: Request, call_next):
    response = await call_next(request)
    path = request.url.path
    if path.startswith("/static/") and (
        path.endswith(".css") or path.endswith(".svg")
    ) and "Cache-Control" not in response.headers:
        # Only set immutable if the URL has a cache-buster (?v=…).
        # @import-ed CSS sub-files have no version param and must stay revalidatable.
        if request.url.query and request.url.query.startswith("v="):
            response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
        else:
            response.headers["Cache-Control"] = "no-cache"
    return response


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
        # Expose the build version to JS so the service worker URL and cache
        # bust use the same identifier across page loads.
        html = html.replace(
            "</head>",
            f'<script>window.ROONSAGE_VERSION={_json.dumps(v)};</script></head>',
            1,
        )
        return HTMLResponse(html, headers={"Cache-Control": "no-cache"})
    return {"message": "RoonSage API is running. Frontend not found."}


@app.get("/mobile")
@app.get("/mobile.html")
async def serve_mobile():
    """Serve the mobile shell. Reuses the same StaticFiles tree under /static."""
    mobile_path = frontend_path / "mobile.html"
    if mobile_path.exists():
        return HTMLResponse(mobile_path.read_text(), headers={"Cache-Control": "no-cache"})
    return Response(status_code=404)


@app.get("/sw.js")
async def serve_service_worker():
    """Serve the service worker from the root so its scope covers the whole app.

    The ``Service-Worker-Allowed`` header is harmless from root scope but kept
    for parity if the file ever moves. ``?v=<version>`` is forwarded to the
    SW as a build tag so a new deploy invalidates the shell cache.
    """
    sw_path = frontend_path / "sw.js"
    if not sw_path.exists():
        return Response(status_code=404)
    return FileResponse(
        sw_path,
        media_type="application/javascript",
        headers={
            "Cache-Control": "no-cache, must-revalidate",
            "Service-Worker-Allowed": "/",
        },
    )


@app.get("/manifest.json")
async def serve_manifest():
    """Serve the PWA manifest from root (matches the link in index.html)."""
    manifest_path = frontend_path / "manifest.json"
    if not manifest_path.exists():
        return Response(status_code=404)
    return FileResponse(
        manifest_path,
        media_type="application/manifest+json",
        headers={"Cache-Control": "public, max-age=3600"},
    )
