"""Qobuz playlist save endpoints — playlist management, favorites, discovery, and Arc prep."""

import asyncio
import datetime
import logging

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

from backend.config import get_qobuz_config
from backend.dependencies import check_rate_limit
from backend.models import (
    PrepareForArcRequest,
    PrepareForArcResponse,
    QobuzAlbumSummary,
    QobuzFavoriteRequest,
    QobuzFavoritesResponse,
    QobuzNewReleasesResponse,
    QobuzPlaylistsResponse,
    QobuzPlaylistSummary,
    QobuzPlaylistUpdateRequest,
    QobuzPlaylistUpdateResponse,
)
from backend.qobuz_api import (
    QobuzAPIError,
    get_qobuz_api_client,
    get_qobuz_api_error,
    init_qobuz_api_client,
)

logger = logging.getLogger(__name__)

router = APIRouter()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _require_client():
    """Return the Qobuz API client or raise 400 if not configured."""
    client = get_qobuz_api_client()
    if not client or not client.is_authenticated():
        raise HTTPException(
            status_code=400,
            detail=(
                "Qobuz is not configured. "
                "Set QOBUZ_EMAIL and QOBUZ_PASSWORD environment variables."
            ),
        )
    return client


# ---------------------------------------------------------------------------
# Legacy models (kept here to avoid breaking the existing endpoint)
# ---------------------------------------------------------------------------


class TrackInput(BaseModel):
    artist: str
    title: str


class SaveQobuzPlaylistRequest(BaseModel):
    name: str
    description: str | None = ""
    tracks: list[TrackInput]
    is_public: bool | None = False


@router.post("/api/qobuz/playlist/save")
async def save_qobuz_playlist(req: SaveQobuzPlaylistRequest):
    """Save a playlist to the user's Qobuz account.

    Resolves each track by artist+title via Qobuz search API,
    creates a new playlist, and adds matched tracks.
    """
    client = get_qobuz_api_client()
    if not client:
        raise HTTPException(
            status_code=503,
            detail=(
                "Qobuz API niet geconfigureerd. "
                "Stel QOBUZ_EMAIL en QOBUZ_PASSWORD in."
            ),
        )

    tracks_dicts = [{"artist": t.artist, "title": t.title} for t in req.tracks]

    if len(tracks_dicts) > 2000:
        raise HTTPException(
            status_code=400,
            detail="Qobuz staat maximaal 2000 tracks per playlist toe.",
        )

    result = await asyncio.to_thread(
        client.save_playlist,
        name=req.name,
        tracks=tracks_dicts,
        description=req.description or "",
        is_public=req.is_public or False,
    )
    return result


@router.get("/api/qobuz/save-status")
async def qobuz_save_status():
    """Check if Qobuz playlist save is configured and available."""
    client = get_qobuz_api_client()
    error = get_qobuz_api_error()
    return {
        "available": client is not None and client.is_authenticated(),
        "error": error,
        "display_name": client._user_display_name if client else None,
    }


class ValidateQobuzRequest(BaseModel):
    email: str | None = None
    password: str | None = None


@router.post("/api/qobuz/validate")
async def validate_qobuz_credentials(req: ValidateQobuzRequest):
    """Validate Qobuz credentials by attempting to log in.

    Accepts {"email": "...", "password": "..."} in the body to test specific
    credentials. If no body fields are provided, uses the currently configured
    credentials from environment / config.user.yaml.

    The app_id and app_secret are auto-extracted from the Qobuz web player —
    the caller never needs to supply them.
    """
    if req.email and req.password:
        email = req.email
        password = req.password
    else:
        qobuz_cfg = get_qobuz_config()
        email = qobuz_cfg.get("email", "")
        password = qobuz_cfg.get("password", "")

    if not (email and password):
        return {
            "available": False,
            "error": "Vul e-mailadres en wachtwoord in.",
        }

    # Re-initialize the singleton; app credentials extracted automatically
    client = await asyncio.to_thread(init_qobuz_api_client, email, password)
    error = get_qobuz_api_error()

    available = client is not None and client.is_authenticated()

    return {
        "available": available,
        "error": error,
        "user_display": client.user_display if available else None,
        "subscription": client.subscription if available else None,
    }


# =============================================================================
# Favorites
# =============================================================================


@router.post("/api/qobuz/favorite/add", dependencies=[Depends(check_rate_limit)])
async def add_qobuz_favorite(req: QobuzFavoriteRequest):
    """Add tracks, albums, or artists to Qobuz favorites.

    Body: {"type": "track"|"album"|"artist", "ids": ["123", "456"]}
    """
    client = _require_client()
    try:
        result = await asyncio.to_thread(client.add_favorite, req.type, req.ids)
        return {"success": True, "type": req.type, "ids": req.ids, "result": result}
    except QobuzAPIError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    except Exception as exc:
        logger.error("Qobuz add_favorite failed: %s", exc)
        raise HTTPException(status_code=500, detail=f"Qobuz API error: {exc}")


@router.post("/api/qobuz/favorite/remove", dependencies=[Depends(check_rate_limit)])
async def remove_qobuz_favorite(req: QobuzFavoriteRequest):
    """Remove tracks, albums, or artists from Qobuz favorites.

    Body: {"type": "track"|"album"|"artist", "ids": ["123", "456"]}
    """
    client = _require_client()
    try:
        result = await asyncio.to_thread(client.remove_favorite, req.type, req.ids)
        return {"success": True, "type": req.type, "ids": req.ids, "result": result}
    except QobuzAPIError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    except Exception as exc:
        logger.error("Qobuz remove_favorite failed: %s", exc)
        raise HTTPException(status_code=500, detail=f"Qobuz API error: {exc}")


@router.get("/api/qobuz/favorites")
async def get_qobuz_favorites(
    type: str = Query("albums", description="'tracks', 'albums', or 'artists'"),
    limit: int = Query(500, ge=1, le=2000),
):
    """Get user's Qobuz favorites.

    Query params: type=tracks|albums|artists, limit=500
    """
    client = _require_client()
    valid_types = {"tracks", "albums", "artists"}
    if type not in valid_types:
        raise HTTPException(status_code=400, detail=f"type must be one of: {', '.join(sorted(valid_types))}")
    try:
        result = await asyncio.to_thread(client.get_favorites, type, limit)
        # Unify the response — different item types use different key names
        items = (
            result.get("tracks", {}).get("items")
            or result.get("albums", {}).get("items")
            or result.get("artists", {}).get("items")
            or []
        )
        total = (
            result.get("tracks", {}).get("total")
            or result.get("albums", {}).get("total")
            or result.get("artists", {}).get("total")
            or len(items)
        )
        return QobuzFavoritesResponse(type=type, items=items, total=total)
    except QobuzAPIError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    except Exception as exc:
        logger.error("Qobuz get_favorites failed: %s", exc)
        raise HTTPException(status_code=500, detail=f"Qobuz API error: {exc}")


# =============================================================================
# Playlist management
# =============================================================================


@router.get("/api/qobuz/playlists")
async def list_qobuz_playlists(limit: int = Query(50, ge=1, le=500)):
    """List all user playlists on Qobuz."""
    client = _require_client()
    try:
        playlists = await asyncio.to_thread(client.get_user_playlists, limit)
        summaries = [QobuzPlaylistSummary(**p) for p in playlists]
        return QobuzPlaylistsResponse(playlists=summaries, total=len(summaries))
    except QobuzAPIError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    except Exception as exc:
        logger.error("Qobuz list_playlists failed: %s", exc)
        raise HTTPException(status_code=500, detail=f"Qobuz API error: {exc}")


@router.get("/api/qobuz/playlist/{playlist_id}")
async def get_qobuz_playlist(playlist_id: str):
    """Get Qobuz playlist details including tracks."""
    client = _require_client()
    try:
        result = await asyncio.to_thread(client.get_playlist, playlist_id)
        return result
    except QobuzAPIError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    except Exception as exc:
        logger.error("Qobuz get_playlist failed: %s", exc)
        raise HTTPException(status_code=500, detail=f"Qobuz API error: {exc}")


@router.put("/api/qobuz/playlist/{playlist_id}")
async def update_qobuz_playlist(playlist_id: str, req: QobuzPlaylistUpdateRequest):
    """Update a Qobuz playlist: rename, add tracks, or remove tracks.

    Body: {name?, description?, add_track_ids?, remove_playlist_track_ids?}
    """
    client = _require_client()
    tracks_added = 0
    tracks_removed = 0
    try:
        # Update metadata if requested
        if req.name is not None or req.description is not None:
            await asyncio.to_thread(client.update_playlist, playlist_id, req.name, req.description)

        # Add new tracks
        if req.add_track_ids:
            await asyncio.to_thread(client.add_tracks_to_playlist_by_id, playlist_id, req.add_track_ids)
            tracks_added = len(req.add_track_ids)

        # Remove tracks
        if req.remove_playlist_track_ids:
            await asyncio.to_thread(client.remove_tracks_from_playlist, playlist_id, req.remove_playlist_track_ids)
            tracks_removed = len(req.remove_playlist_track_ids)

        return QobuzPlaylistUpdateResponse(
            success=True,
            playlist_id=playlist_id,
            tracks_added=tracks_added,
            tracks_removed=tracks_removed,
        )
    except QobuzAPIError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    except Exception as exc:
        logger.error("Qobuz update_playlist failed: %s", exc)
        raise HTTPException(status_code=500, detail=f"Qobuz API error: {exc}")


@router.delete("/api/qobuz/playlist/{playlist_id}")
async def delete_qobuz_playlist(playlist_id: str):
    """Delete a Qobuz playlist permanently."""
    client = _require_client()
    try:
        result = await asyncio.to_thread(client.delete_playlist, playlist_id)
        return {"success": True, "playlist_id": playlist_id, "result": result}
    except QobuzAPIError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    except Exception as exc:
        logger.error("Qobuz delete_playlist failed: %s", exc)
        raise HTTPException(status_code=500, detail=f"Qobuz API error: {exc}")


# =============================================================================
# Discovery — new releases
# =============================================================================


@router.get("/api/qobuz/new-releases")
async def qobuz_new_releases(
    genre_id: str | None = Query(None, description="Qobuz genre ID (optional)"),
    limit: int = Query(50, ge=1, le=200),
):
    """Get new/featured album releases from Qobuz."""
    client = _require_client()
    try:
        albums = await asyncio.to_thread(client.get_new_releases, genre_id, limit)
        summaries = [QobuzAlbumSummary(**a) for a in albums]
        return QobuzNewReleasesResponse(albums=summaries, total=len(summaries))
    except QobuzAPIError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    except Exception as exc:
        logger.error("Qobuz new_releases failed: %s", exc)
        raise HTTPException(status_code=500, detail=f"Qobuz API error: {exc}")


# =============================================================================
# Arc workflow — prepare playlist for Roon Arc via Qobuz
# =============================================================================


@router.post("/api/qobuz/prepare-for-arc")
async def prepare_for_arc(req: PrepareForArcRequest):
    """Resolve tracks to Qobuz, create a playlist, and optionally add albums to favorites.

    Workflow:
    1. Resolve each track to a Qobuz track ID via search + fuzzy matching.
    2. Create a Qobuz playlist named "RoonSage · {playlist_name} · {date}".
    3. Add matched tracks to the playlist.
    4. If add_to_favorites: add unique albums to Qobuz favorites.
    5. Return counts and playlist details.
    """
    client = _require_client()

    # Build track dicts for resolve_tracks
    track_dicts = [{"artist": t.artist, "title": t.title} for t in req.track_items]
    if not track_dicts:
        raise HTTPException(status_code=400, detail="No tracks provided.")
    if len(track_dicts) > 2000:
        raise HTTPException(status_code=400, detail="Maximum 2000 tracks per request.")

    try:
        # Step 1: Resolve
        resolved = await asyncio.to_thread(client.resolve_tracks, track_dicts)
        matched = resolved["matched"]
        unmatched = resolved["unmatched"]

        if not matched:
            return PrepareForArcResponse(
                success=False,
                tracks_resolved=0,
                tracks_skipped=len(unmatched),
                error="No tracks could be resolved on Qobuz.",
            )

        # Step 2: Create playlist
        today = datetime.date.today().strftime("%Y-%m-%d")
        playlist_name = f"RoonSage · {req.playlist_name} · {today}"
        playlist = await asyncio.to_thread(
            client.create_playlist, playlist_name, "", False
        )
        playlist_id = str(playlist.get("id", ""))

        # Step 3: Add tracks
        qobuz_ids = [str(t["qobuz_id"]) for t in matched]
        for i in range(0, len(qobuz_ids), 50):
            batch = qobuz_ids[i: i + 50]
            await asyncio.to_thread(client.add_tracks_to_playlist, int(playlist_id), [int(tid) for tid in batch])
            if i + 50 < len(qobuz_ids):
                await asyncio.to_thread(__import__("time").sleep, 0.3)

        # Step 4: Add albums to favorites (optional)
        albums_favorited = 0
        if req.add_to_favorites and matched:
            # Collect unique album IDs from matched tracks
            # We need album IDs which aren't directly in our matched data.
            # Search each unique artist+album combo to get album ID.
            seen_albums: set[str] = set()
            album_ids_to_fav: list[str] = []
            for m in matched:
                key = m.get("artist", "")
                if key and key not in seen_albums:
                    seen_albums.add(key)
                    # search for album to get its ID
                    results = await asyncio.to_thread(client.search_track, f"{m['artist']} {m['title']}", 1)
                    if results:
                        album_obj = results[0].get("album", {})
                        album_id = album_obj.get("id") if isinstance(album_obj, dict) else None
                        if album_id:
                            album_ids_to_fav.append(str(album_id))
            if album_ids_to_fav:
                # Deduplicate
                album_ids_to_fav = list(dict.fromkeys(album_ids_to_fav))
                await asyncio.to_thread(client.add_favorite, "album", album_ids_to_fav)
                albums_favorited = len(album_ids_to_fav)

        playlist_url = f"https://play.qobuz.com/playlist/{playlist_id}"
        return PrepareForArcResponse(
            success=True,
            playlist_id=playlist_id,
            playlist_url=playlist_url,
            playlist_name=playlist_name,
            tracks_resolved=len(matched),
            tracks_skipped=len(unmatched),
            albums_favorited=albums_favorited,
        )

    except QobuzAPIError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    except Exception as exc:
        logger.error("prepare_for_arc failed: %s", exc, exc_info=True)
        raise HTTPException(status_code=500, detail=f"Qobuz API error: {exc}")
