"""Discovery endpoints — Cache-Powered Discovery (zero LLM, zero external APIs).

All data is derived from the existing SQLite library cache via pure SQL queries.

Endpoints
---------
GET /api/discovery/sections            — all 4 sections in one call
GET /api/discovery/undiscovered-albums — just the undiscovered albums section
GET /api/discovery/genre-explorer      — just the genre explorer section
"""

import logging

from fastapi import APIRouter

from backend.discovery import (
    get_deep_cuts,
    get_forgotten_favorites,
    get_genre_explorer,
    get_undiscovered_albums,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/discovery", tags=["discovery"])


@router.get("/sections")
async def get_all_discovery_sections() -> dict:
    """Return all 4 discovery sections as a single JSON object.

    Sections:
    - undiscovered_albums  Albums by favourite artists with zero plays
    - deep_cuts            Under-played tracks from top artists
    - forgotten_favorites  High-play tracks not heard in 60+ days
    - genre_explorer       Genre breakdown with artist & track counts
    """
    try:
        undiscovered = get_undiscovered_albums()
        cuts = get_deep_cuts()
        forgotten = get_forgotten_favorites()
        genres = get_genre_explorer()
    except Exception:
        logger.exception("get_all_discovery_sections failed")
        undiscovered, cuts, forgotten, genres = [], [], [], []

    return {
        "undiscovered_albums": undiscovered,
        "deep_cuts": cuts,
        "forgotten_favorites": forgotten,
        "genre_explorer": genres,
    }


@router.get("/undiscovered-albums")
async def get_undiscovered_albums_endpoint() -> list:
    """Return albums by the user's most-played artists that have zero plays."""
    return get_undiscovered_albums()


@router.get("/genre-explorer")
async def get_genre_explorer_endpoint() -> list:
    """Return genre breakdown sorted by artist count."""
    return get_genre_explorer()
