"""FastAPI application for RoonSage."""

import base64
import json as _json
import logging
import os
import secrets
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from backend.dependencies import ROONSAGE_PASSWORD, limiter
from backend.routes import config_routes, generate, library, recommend, results, roon, setup
from backend.routes.automations import router as automations_router
from backend.routes.discovery import router as discovery_router
from backend.routes.enrichment import router as enrichment_router
from backend.routes.intelligence import router as intelligence_router
from backend.routes.notifications import router as notifications_router
from backend.routes.qobuz_playlist import router as qobuz_playlist_router
from backend.routes.scheduler import router as scheduler_router
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

# =============================================================================
# CORS middleware — origins controlled via CORS_ORIGINS env var
# =============================================================================

app.add_middleware(
    CORSMiddleware,
    allow_origins=os.environ.get("CORS_ORIGINS", "http://localhost:5765").split(","),
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
app.include_router(verify_router)


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
