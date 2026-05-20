"""Watchlist endpoints — artist new-release monitoring for RoonSage."""

from __future__ import annotations

import logging
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/watchlist", tags=["watchlist"])


# ---------------------------------------------------------------------------
# Pydantic models
# ---------------------------------------------------------------------------


class AddArtistRequest(BaseModel):
    artist_name: str
    monitor_albums: bool = True
    monitor_eps: bool = True
    monitor_singles: bool = False


class UpdateArtistRequest(BaseModel):
    monitor_albums: Optional[bool] = None
    monitor_eps: Optional[bool] = None
    monitor_singles: Optional[bool] = None


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.get("")
async def list_watchlist() -> list[dict]:
    """Return all watched artists with their status and unnotified release count."""
    from backend.watchlist import get_watchlist  # noqa: PLC0415
    return get_watchlist()


@router.post("")
async def add_artist(body: AddArtistRequest) -> dict:
    """Add an artist to the watchlist (idempotent)."""
    from backend.watchlist import add_to_watchlist  # noqa: PLC0415
    artist = body.artist_name.strip()
    if not artist:
        raise HTTPException(status_code=400, detail="artist_name must not be empty")
    result = add_to_watchlist(
        artist,
        monitor_albums=body.monitor_albums,
        monitor_eps=body.monitor_eps,
        monitor_singles=body.monitor_singles,
    )
    return result


@router.patch("/{artist_name}")
async def update_artist(artist_name: str, body: UpdateArtistRequest) -> dict:
    """Update monitor flags for a watched artist."""
    from backend.watchlist import update_watchlist_entry  # noqa: PLC0415
    result = update_watchlist_entry(
        artist_name,
        monitor_albums=body.monitor_albums,
        monitor_eps=body.monitor_eps,
        monitor_singles=body.monitor_singles,
    )
    if not result:
        raise HTTPException(status_code=404, detail=f"Artist '{artist_name}' not in watchlist")
    return result


@router.delete("/{artist_name}")
async def remove_artist(artist_name: str) -> dict:
    """Remove an artist from the watchlist (also clears release cache for that artist)."""
    from backend.watchlist import remove_from_watchlist  # noqa: PLC0415
    removed = remove_from_watchlist(artist_name)
    if not removed:
        raise HTTPException(status_code=404, detail=f"Artist '{artist_name}' not in watchlist")
    return {"removed": True, "artist_name": artist_name}


@router.post("/auto-populate")
async def auto_populate() -> dict:
    """Auto-add top artists from the taste profile to the watchlist."""
    from backend.watchlist import auto_populate_watchlist  # noqa: PLC0415
    added = auto_populate_watchlist()
    return {"added": added, "count": len(added)}


@router.post("/scan")
async def trigger_scan() -> dict:
    """Trigger an immediate scan of all watched artists for new releases."""
    from backend.watchlist import scan_all_watched  # noqa: PLC0415
    try:
        new_releases = await scan_all_watched()
        return {
            "scanned": True,
            "new_releases_found": len(new_releases),
            "releases": new_releases,
        }
    except Exception as exc:
        logger.error("Watchlist scan failed: %s", exc)
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@router.get("/new-releases")
async def list_new_releases(include_dismissed: bool = False) -> list[dict]:
    """Return all unnotified (or all) new releases from the releases cache."""
    from backend.watchlist import get_new_releases  # noqa: PLC0415
    return get_new_releases(notified=include_dismissed)


@router.post("/new-releases/{release_id}/dismiss")
async def dismiss_release(release_id: int) -> dict:
    """Mark a release as notified/dismissed."""
    from backend.watchlist import dismiss_release as _dismiss  # noqa: PLC0415
    ok = _dismiss(release_id)
    if not ok:
        raise HTTPException(status_code=404, detail=f"Release id {release_id} not found")
    return {"dismissed": True, "id": release_id}
