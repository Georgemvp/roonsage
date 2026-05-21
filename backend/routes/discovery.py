"""Discovery endpoints — Cache-Powered Discovery (zero LLM, zero external APIs)."""

import logging

from fastapi import APIRouter

from backend.discovery import (
    get_deep_cuts,
    get_favorites_in_library,
    get_forgotten_favorites,
    get_genre_explorer,
    get_lb_loved_in_library,
    get_lb_top_releases_in_library,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/discovery", tags=["discovery"])


@router.get("/sections")
async def get_all_discovery_sections() -> dict:
    try:
        favorites      = get_favorites_in_library()
        lb_releases    = get_lb_top_releases_in_library()
        lb_loved       = get_lb_loved_in_library()
        cuts           = get_deep_cuts()
        forgotten      = get_forgotten_favorites()
        genres         = get_genre_explorer()
    except Exception:
        logger.exception("get_all_discovery_sections failed")
        favorites, lb_releases, lb_loved, cuts, forgotten, genres = [], [], [], [], [], []

    return {
        "favorites_in_library": favorites,
        "lb_top_releases":      lb_releases,
        "lb_loved_in_library":  lb_loved,
        "deep_cuts":            cuts,
        "forgotten_favorites":  forgotten,
        "genre_explorer":       genres,
    }


@router.get("/genre-explorer")
async def get_genre_explorer_endpoint() -> list:
    return get_genre_explorer()
