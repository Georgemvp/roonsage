"""Library cache and filter endpoints."""

import asyncio
import random as _random

from fastapi import APIRouter, HTTPException, Query

from backend import library_cache
from backend.config import get_config
from backend.filter_sessions import get_session, store_session
from backend.llm_client import estimate_cost_for_model
from backend.models import (
    DecadeCount,
    FilterLibraryRequest,
    FilterLibraryResponse,
    FilterPreviewRequest,
    FilterPreviewResponse,
    GenreCount,
    LibraryCacheStatusResponse,
    LibraryStatsResponse,
    SyncProgress,
    SyncTriggerResponse,
    Track,
)
from backend.roon_client import get_roon_client

router = APIRouter(prefix="/api", tags=["library"])


@router.get("/library/status", response_model=LibraryCacheStatusResponse)
async def get_library_status() -> LibraryCacheStatusResponse:
    """Get library cache status for UI polling."""
    roon_client = get_roon_client()

    state = library_cache.get_sync_state()

    sync_progress = None
    if state["sync_progress"]:
        sync_progress = SyncProgress(
            phase=state["sync_progress"]["phase"],
            current=state["sync_progress"]["current"],
            total=state["sync_progress"]["total"],
        )

    return LibraryCacheStatusResponse(
        track_count=state["track_count"],
        synced_at=state["synced_at"],
        is_syncing=state["is_syncing"],
        sync_progress=sync_progress,
        error=state["error"],
        roon_connected=roon_client.is_connected() if roon_client else False,
        needs_resync=library_cache.needs_resync(),
    )


@router.post("/library/sync", response_model=SyncTriggerResponse)
async def trigger_library_sync() -> SyncTriggerResponse:
    """Trigger library sync from Roon.

    Always starts sync in background so progress can be polled.
    """
    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")

    progress = library_cache.get_sync_progress()
    if progress["is_syncing"]:
        raise HTTPException(status_code=409, detail="Sync already in progress")

    asyncio.create_task(
        asyncio.to_thread(library_cache.sync_library, roon_client)
    )
    return SyncTriggerResponse(started=True, blocking=False)


@router.get("/library/stats", response_model=LibraryStatsResponse)
async def get_library_stats() -> LibraryStatsResponse:
    """Get library statistics."""
    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")

    stats = await asyncio.to_thread(roon_client.get_library_stats)
    return LibraryStatsResponse(
        total_tracks=stats.get("total_tracks", 0),
        genres=[GenreCount(**g) for g in stats.get("genres", [])],
        decades=[DecadeCount(**d) for d in stats.get("decades", [])],
    )


@router.get("/library/stats/cached", response_model=LibraryStatsResponse)
async def get_library_stats_cached() -> LibraryStatsResponse:
    """Get genre/decade stats from the local cache (no Roon round-trip)."""
    stats = await asyncio.to_thread(library_cache.get_cached_genre_decade_stats)
    return LibraryStatsResponse(
        total_tracks=stats.get("total_tracks", 0),
        genres=[GenreCount(**g) for g in stats["genres"]],
        decades=[DecadeCount(**d) for d in stats["decades"]],
    )


@router.get("/library/artist-albums")
async def get_artist_albums(
    artist: str = Query(..., description="Artist name (partial match, case-insensitive)"),
    max_albums: int = Query(50, ge=1, le=200, description="Maximum number of albums to return"),
) -> list[dict]:
    """Return all albums in the cache by a given artist."""
    return await asyncio.to_thread(library_cache.get_albums_by_artist, artist, max_albums)


@router.get("/library/search", response_model=list[Track])
async def search_library(
    q: str = Query(..., description="Search query"),
) -> list[Track]:
    """Search for tracks -- cache first, Roon API fallback."""
    # Normalize smart/curly quotes to straight quotes (iOS auto-correction)
    normalized = (
        q.replace('\u2018', "'").replace('\u2019', "'")
         .replace('\u201c', '"').replace('\u201d', '"')
    )

    # Try cache first (fast, reliable, works offline)
    if library_cache.has_cached_tracks():
        cached = await asyncio.to_thread(
            library_cache.search_cached_tracks, normalized, 20
        )
        if cached:
            return [
                Track(
                    rating_key=t["rating_key"],
                    title=t["title"],
                    artist=t["artist"],
                    album=t["album"],
                    duration_ms=t.get("duration_ms") or 0,
                    year=t.get("year"),
                    genres=t.get("genres") or [],
                )
                for t in cached
            ]

    # Fallback to live Roon search
    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        raise HTTPException(
            status_code=503, detail="Roon not connected"
        )
    return await asyncio.to_thread(
        roon_client.search_tracks, normalized
    )


@router.post("/library/filter", response_model=FilterLibraryResponse)
async def filter_library_tracks(request: FilterLibraryRequest) -> FilterLibraryResponse:
    """Return filtered tracks from the local SQLite library cache."""
    if not library_cache.has_cached_tracks():
        raise HTTPException(status_code=400, detail="Library cache is empty. Please sync your library first.")

    genres = request.genres if request.genres else None
    decades = request.decades if request.decades else None

    raw_tracks = await asyncio.to_thread(
        library_cache.get_tracks_by_filters,
        genres=genres,
        decades=decades,
        exclude_live=request.exclude_live,
        limit=0,
    )

    total_matching = len(raw_tracks)

    if request.max_tracks > 0 and total_matching > request.max_tracks:
        raw_tracks = _random.sample(raw_tracks, request.max_tracks)

    tracks = [
        Track(
            rating_key=t["rating_key"],
            title=t["title"],
            artist=t["artist"],
            album=t["album"],
            duration_ms=t.get("duration_ms") or 0,
            year=t.get("year"),
            genres=t.get("genres") or [],
        )
        for t in raw_tracks
    ]

    return FilterLibraryResponse(
        total_matching=total_matching,
        returned=len(tracks),
        tracks=tracks,
    )


@router.post("/filter/preview", response_model=FilterPreviewResponse)
async def preview_filters(request: FilterPreviewRequest) -> FilterPreviewResponse:
    """Preview filter results with track count and cost estimate."""
    roon_client = get_roon_client()
    config = get_config()

    genres = request.genres if request.genres else None
    decades = request.decades if request.decades else None
    exclude_live = request.exclude_live

    matching_tracks = -1
    if library_cache.has_cached_tracks():
        matching_tracks = await asyncio.to_thread(
            library_cache.count_tracks_by_filters,
            genres=genres,
            decades=decades,
            exclude_live=exclude_live,
        )

    if matching_tracks < 0:
        sync_progress = library_cache.get_sync_progress()
        if sync_progress["is_syncing"]:
            matching_tracks = 0
        elif not roon_client or not roon_client.is_connected():
            raise HTTPException(status_code=503, detail="Roon not connected")
        else:
            matching_tracks = await asyncio.to_thread(
                roon_client.count_tracks_by_filters,
                genres=genres,
                decades=decades,
                exclude_live=exclude_live,
            )

    if matching_tracks <= 0:
        tracks_to_send = 0
    elif request.max_tracks_to_ai == 0:
        tracks_to_send = matching_tracks
    else:
        tracks_to_send = min(matching_tracks, request.max_tracks_to_ai)

    analysis_input = 1100
    analysis_output = 300
    generation_input = tracks_to_send * 40
    generation_output = request.track_count * 60

    estimated_input_tokens = analysis_input + generation_input
    estimated_output_tokens = analysis_output + generation_output

    analysis_cost = estimate_cost_for_model(
        config.llm.model_analysis,
        analysis_input,
        analysis_output,
        config=config.llm,
    )
    generation_cost = estimate_cost_for_model(
        config.llm.model_generation,
        generation_input,
        generation_output,
        config=config.llm,
    )
    estimated_cost = analysis_cost + generation_cost

    return FilterPreviewResponse(
        matching_tracks=matching_tracks,
        tracks_to_send=tracks_to_send,
        estimated_input_tokens=estimated_input_tokens,
        estimated_output_tokens=estimated_output_tokens,
        estimated_cost=estimated_cost,
    )


# ---------------------------------------------------------------------------
# Filter session endpoints — server-side key_map storage for MCP curation
# ---------------------------------------------------------------------------


@router.post("/library/filter/session")
async def store_filter_session(request: dict) -> dict:
    """Store a key_map from filter results server-side and return a session_id.

    Called by the MCP server after filter_tracks to avoid passing the full
    key_map through Claude's context window.
    """
    key_map = request.get("key_map", {})
    total = request.get("total_matching", 0)
    returned = request.get("returned", 0)
    session_id = store_session(key_map, total, returned)
    return {"session_id": session_id}


@router.post("/library/filter/curate")
async def curate_from_session(request: dict) -> dict:
    """Translate track numbers to Roon item_keys using a stored session and queue them.

    Used by the MCP curate_and_play tool: Claude supplies track numbers (from the
    compact numbered list) and the session_id returned by filter_tracks.  The server
    looks up the key_map, translates numbers → item_keys, and starts/appends playback.
    """
    session_id = request.get("session_id")
    track_numbers = request.get("track_numbers", [])
    zone_id = request.get("zone_id")
    append = request.get("append", False)

    if not session_id or not track_numbers or not zone_id:
        raise HTTPException(
            status_code=400,
            detail="session_id, track_numbers, and zone_id are required",
        )

    session = get_session(session_id)
    if not session:
        raise HTTPException(
            status_code=404,
            detail="Filter session expired or not found. Call filter_tracks again.",
        )

    key_map = session["key_map"]
    item_keys: list[str] = []
    missing: list[int] = []
    for num in track_numbers:
        key = key_map.get(str(num))
        if key:
            item_keys.append(key)
        else:
            missing.append(num)

    if not item_keys:
        return {"success": False, "error": "No valid track numbers", "missing": missing}

    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")

    mode = "add_next" if append else "replace"
    result = await asyncio.to_thread(roon_client.play_tracks, zone_id, item_keys, mode)

    return {
        "success": result.get("success", False),
        "tracks_queued": len(item_keys),
        "zone_name": result.get("zone_name", zone_id),
        "missing_numbers": missing if missing else None,
    }
