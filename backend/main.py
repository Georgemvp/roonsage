"""FastAPI application for MediaSage."""

import asyncio
import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse

from backend.config import get_config
from backend.version import get_version
from backend.roon_client import get_roon_client, init_roon_client
from backend import library_cache
from backend.llm_client import init_llm_client
from backend.routes import setup, library, generate, recommend, roon, config_routes, results
import backend.routes.recommend as _recommend_module

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize clients on startup."""
    config = get_config()

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

    yield

    # Shutdown: clean up resources (read from module to get current values, not import-time snapshot)
    if _recommend_module._music_research_client is not None:
        await _recommend_module._music_research_client.close()
    if _recommend_module._art_proxy_client is not None:
        await _recommend_module._art_proxy_client.aclose()


app = FastAPI(
    title="MediaSage",
    description="Roon AI playlist generator powered by LLMs",
    version=get_version(),
    lifespan=lifespan,
)

# Register all routers
app.include_router(setup.router)
app.include_router(library.router)
app.include_router(generate.router)
app.include_router(recommend.router)
app.include_router(roon.router)
app.include_router(config_routes.router)
app.include_router(results.router)


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
    return {"message": "MediaSage API is running. Frontend not found."}
