"""Library cache and filter endpoints."""

import asyncio
import random as _random
from collections import defaultdict

from fastapi import APIRouter, HTTPException, Query

from backend import library_cache
from backend.config import get_config
from backend.filter_sessions import get_session, store_session
from backend.roon_client import get_roon_client
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

# ---------------------------------------------------------------------------
# Playlist-validatie helpers
# ---------------------------------------------------------------------------


def _validate_track_selection(
    track_numbers: list[int],
    key_map: dict[str, str],
    track_meta: dict[str, dict],
    max_per_artist: int = 2,
) -> dict:
    """Validate a curated track selection for duplicates, clustering, overrepresentation.

    Args:
        track_numbers: Ordered list of track numbers selected by Claude.
        key_map:       Maps str(number) → item_key.
        track_meta:    Maps item_key → {artist, title, album}.
        max_per_artist: Max acceptable count per artist.

    Returns:
        {"valid": bool, "warnings": [...]}
    """
    warnings: list[dict] = []

    # Resolve numbers → metadata; skip unknown numbers (warn separately)
    resolved: list[tuple[int, str, str, str]] = []  # (position, item_key, artist, title)
    for pos, num in enumerate(track_numbers, start=1):
        rk = key_map.get(str(num))
        if not rk:
            warnings.append({"type": "unknown_number", "position": pos, "number": num})
            continue
        meta = track_meta.get(rk, {})
        artist = meta.get("artist", "")
        title = meta.get("title", "")
        resolved.append((pos, rk, artist.lower(), title.lower()))

    # 1. Duplicates (same artist + title at two different positions)
    seen: dict[tuple[str, str], list[int]] = {}
    for pos, rk, artist, title in resolved:
        key = (artist, title)
        seen.setdefault(key, []).append(pos)
    for (artist, title), positions in seen.items():
        if len(positions) > 1:
            # Recover original casing from meta
            orig_artist = ""
            orig_title = ""
            rk = key_map.get(str(track_numbers[positions[0] - 1]))
            if rk and rk in track_meta:
                orig_artist = track_meta[rk].get("artist", artist)
                orig_title = track_meta[rk].get("title", title)
            warnings.append({
                "type": "duplicate",
                "positions": positions,
                "artist": orig_artist,
                "title": orig_title,
            })

    # 2. Clustering (same artist on consecutive positions)
    for idx in range(len(resolved) - 1):
        pos_a, _, artist_a, _ = resolved[idx]
        pos_b, _, artist_b, _ = resolved[idx + 1]
        if artist_a and artist_a == artist_b:
            orig_artist = track_meta.get(key_map.get(str(track_numbers[idx]), ""), {}).get("artist", artist_a)
            warnings.append({
                "type": "clustering",
                "positions": [pos_a, pos_b],
                "artist": orig_artist,
            })

    # 3. Overrepresentation (more than max_per_artist tracks from same artist)
    artist_counts: dict[str, list[int]] = {}
    for pos, rk, artist, title in resolved:
        artist_counts.setdefault(artist, []).append(pos)
    for artist, positions in artist_counts.items():
        if len(positions) > max_per_artist:
            rk = key_map.get(str(track_numbers[positions[0] - 1]), "")
            orig_artist = track_meta.get(rk, {}).get("artist", artist)
            warnings.append({
                "type": "overrepresented",
                "artist": orig_artist,
                "count": len(positions),
                "max": max_per_artist,
                "positions": positions,
            })

    return {"valid": len(warnings) == 0, "warnings": warnings}


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
                    item_key=t["item_key"],
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

    # --- Wijziging 3: exclude-keywords filter ---
    if request.exclude_keywords:
        kws = [kw.lower() for kw in request.exclude_keywords]
        raw_tracks = [
            t for t in raw_tracks
            if not any(
                kw in (t["title"].lower() + " " + t.get("album", "").lower())
                for kw in kws
            )
        ]

    total_matching = len(raw_tracks)

    # --- Wijziging 2: stratified sampling per artiest ---
    if request.max_tracks > 0 and total_matching > request.max_tracks:
        artist_groups: dict[str, list[dict]] = defaultdict(list)
        for t in raw_tracks:
            artist_groups[t.get("artist", "").lower()].append(t)

        pool: list[dict] = []
        for artist_tracks in artist_groups.values():
            _random.shuffle(artist_tracks)
            pool.extend(artist_tracks[: request.artist_limit])

        _random.shuffle(pool)
        raw_tracks = _random.sample(pool, min(request.max_tracks, len(pool)))

    tracks = [
        Track(
            item_key=t["item_key"],
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

    # Fetch metadata for every resolved key so the MCP caller can show the
    # actual tracklist instead of reconstructing it from memory.
    track_meta = await asyncio.to_thread(library_cache.get_tracks_by_item_keys, item_keys)
    resolved_tracks = []
    for num, key in zip(
        [n for n in track_numbers if key_map.get(str(n))],
        item_keys,
    ):
        meta = track_meta.get(key, {})
        resolved_tracks.append({
            "number": num,
            "title": meta.get("title", key),
            "artist": meta.get("artist", "Unknown"),
        })

    result_dict = result.model_dump()
    return {
        "success": result.success,
        "tracks_queued": len(item_keys),
        "zone_name": result_dict.get("zone_name", zone_id),
        "missing_numbers": missing if missing else None,
        "resolved_tracks": resolved_tracks,
    }


@router.post("/library/filter/validate")
async def validate_playlist_selection(request: dict) -> dict:
    """Validate a curated track selection for duplicates, clustering, and overrepresentation.

    Input:
        session_id:       Session ID from filter_tracks (compact/ultra format).
        track_numbers:    Ordered list of selected track numbers.
        max_per_artist:   Max acceptable tracks per artist (default 2).

    Output:
        {"valid": bool, "warnings": [{type, positions, artist, title?, count?, max?}]}
    """
    session_id = request.get("session_id")
    track_numbers = request.get("track_numbers", [])
    max_per_artist = request.get("max_per_artist", 2)

    if not session_id or not track_numbers:
        raise HTTPException(
            status_code=400,
            detail="session_id and track_numbers are required",
        )

    session = get_session(session_id)
    if not session:
        raise HTTPException(
            status_code=404,
            detail="Filter session expired or not found. Call filter_tracks again.",
        )

    key_map = session["key_map"]

    # Fetch track metadata from SQLite for all referenced item_keys
    item_keys = [key_map[str(n)] for n in track_numbers if str(n) in key_map]
    track_meta = await asyncio.to_thread(library_cache.get_tracks_by_item_keys, item_keys)

    return _validate_track_selection(track_numbers, key_map, track_meta, max_per_artist)
