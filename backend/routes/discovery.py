"""Discovery endpoints — Cache-Powered Discovery (zero LLM, zero external APIs)."""

import logging

from fastapi import APIRouter

from backend.config import get_clap_enabled
from backend.db import get_connection
from backend.discovery import (
    get_deep_cuts,
    get_favorites_in_library,
    get_forgotten_favorites,
    get_genre_explorer,
    get_lb_loved_in_library,
    get_lb_top_releases_in_library,
    get_sounds_like_your_week,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/discovery", tags=["discovery"])


def _sounds_like_your_week_section() -> dict | None:
    """Return the CLAP-powered weekly section, or None when no embeddings exist."""
    if not get_clap_enabled():
        return None
    try:
        with get_connection() as conn:
            n = conn.execute("SELECT COUNT(*) FROM clap_embeddings").fetchone()[0]
    except Exception:
        return None
    if not n:
        return None
    return get_sounds_like_your_week()


@router.get("/sections")
async def get_all_discovery_sections() -> dict:
    try:
        favorites      = get_favorites_in_library()
        lb_releases    = get_lb_top_releases_in_library()
        lb_loved       = get_lb_loved_in_library()
        cuts           = get_deep_cuts()
        forgotten      = get_forgotten_favorites()
        genres         = get_genre_explorer()
        sounds_week    = _sounds_like_your_week_section()
    except Exception:
        logger.exception("get_all_discovery_sections failed")
        favorites, lb_releases, lb_loved, cuts, forgotten, genres = [], [], [], [], [], []
        sounds_week = None

    payload: dict = {
        "favorites_in_library": favorites,
        "lb_top_releases":      lb_releases,
        "lb_loved_in_library":  lb_loved,
        "deep_cuts":            cuts,
        "forgotten_favorites":  forgotten,
        "genre_explorer":       genres,
    }
    if sounds_week is not None:
        payload["sounds_like_your_week"] = sounds_week
    return payload


@router.get("/sounds-like-your-week")
async def sounds_like_your_week_endpoint(limit: int = 20) -> dict:
    if not get_clap_enabled():
        return {
            "tracks": [],
            "window_days": 7,
            "source_count": 0,
            "message": "CLAP_ENABLED=true required.",
        }
    return get_sounds_like_your_week(limit=limit)


@router.get("/genre-explorer")
async def get_genre_explorer_endpoint() -> list:
    return get_genre_explorer()
