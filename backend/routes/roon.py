"""Roon zone, queue, and art proxy endpoints."""

import asyncio
import logging
from urllib.parse import urlparse

from fastapi import APIRouter, HTTPException, Query, Response

from backend.models import (
    BrowsePlaylistsRequest,
    BrowsePlaylistsResponse,
    PlayQueueRequest,
    PlayQueueResponse,
    PlayRadioRequest,
    PlayRadioResponse,
    QobuzSearchRequest,
    QobuzSearchResponse,
    QueueAppendRequest,
    QueueAppendResponse,
    RoonZoneInfo,
    TransferZoneRequest,
    TransferZoneResponse,
    TransportControlRequest,
    TransportControlResponse,
    VolumeControlRequest,
    VolumeControlResponse,
    ZoneGroupingRequest,
    ZoneGroupingResponse,
)
from backend.roon_client import get_roon_client
from backend.routes.recommend import _get_art_proxy_client

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["roon"])

# Allowlist of external art domains (Cover Art Archive CDN).
_EXTERNAL_ART_DOMAINS = {"coverartarchive.org", "archive.org"}


@router.get("/roon/zones", response_model=list[RoonZoneInfo])
async def get_roon_zones() -> list[RoonZoneInfo]:
    """List Roon zones."""
    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")

    return await asyncio.to_thread(roon_client.get_zones)


@router.post("/queue", response_model=PlayQueueResponse)
async def queue_tracks(request: PlayQueueRequest) -> PlayQueueResponse:
    """Queue tracks to a Roon zone."""
    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")

    result = await asyncio.to_thread(
        roon_client.play_tracks,
        request.zone_id,
        request.item_keys,
        request.mode,
    )
    if not result.success:
        raise HTTPException(status_code=500, detail=result.error or "Queue failed")
    return PlayQueueResponse(**result.model_dump())


@router.post("/queue/append", response_model=QueueAppendResponse)
async def queue_append(request: QueueAppendRequest) -> QueueAppendResponse:
    """Append tracks to an existing Roon zone queue."""
    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")

    result = await asyncio.to_thread(
        roon_client.play_tracks,
        request.zone_id,
        request.item_keys,
        "play_next",
    )

    if not result.success:
        raise HTTPException(status_code=500, detail=result.error or "Queue append failed")

    return QueueAppendResponse(
        success=True,
        tracks_added=result.model_dump().get("tracks_queued", 0),
        tracks_skipped=result.model_dump().get("tracks_skipped", 0),
    )


@router.get("/art/{item_key:path}")
async def get_album_art(item_key: str):
    """Proxy album art from Roon by item_key."""
    roon_client = get_roon_client()

    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")

    image_url = await asyncio.to_thread(roon_client.get_image_url, item_key)
    if image_url:
        try:
            client = await _get_art_proxy_client()
            response = await client.get(image_url)
            if response.status_code == 200:
                return Response(
                    content=response.content,
                    media_type=response.headers.get("content-type", "image/jpeg"),
                )
        except Exception:
            logger.debug("Roon art proxy failed for item_key=%s", item_key, exc_info=True)

    raise HTTPException(status_code=404, detail="Art not available")


@router.post("/roon/transport", response_model=TransportControlResponse)
async def transport_control(request: TransportControlRequest) -> TransportControlResponse:
    """Send a transport command to a Roon zone.

    Supports: play, pause, stop, next, previous, shuffle, repeat, seek.
    """
    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected. Retry after connection is established.")

    result = await asyncio.to_thread(
        roon_client.transport_control,
        request.zone_id,
        request.action,
        request.value,
        request.position_seconds,
        request.seek_offset,
    )
    if not result.success:
        raise HTTPException(status_code=400, detail=result.error or "Transport command failed")
    return TransportControlResponse(**result.model_dump())


@router.get("/roon/qobuz-browse-test")
async def qobuz_browse_test(q: str = "Miles Davis"):
    """Debug: navigate Qobuz browse hierarchy step by step."""
    roon = get_roon_client()
    if not roon or not roon._api:
        return {"error": "Roon not connected"}

    steps = []

    def _run():
        try:
            with roon._browse_lock:
                # Step 1: Browse to root
                result = roon._api.browse_browse({"hierarchy": "browse", "pop_all": True})
                count = result.get("list", {}).get("count", 0) if result else 0
                loaded = roon._api.browse_load({"hierarchy": "browse", "count": count})
                items = loaded.get("items", []) if loaded else []
                steps.append({
                    "step": "root",
                    "items": [
                        {"title": i.get("title"), "item_key": i.get("item_key"), "hint": i.get("hint")}
                        for i in items
                    ],
                })

                # Step 2: Find and enter Qobuz
                qobuz_key = None
                for item in items:
                    if "qobuz" in (item.get("title") or "").lower():
                        qobuz_key = item.get("item_key")
                        break

                if not qobuz_key:
                    return {"error": "Qobuz not found in root", "steps": steps}

                result2 = roon._api.browse_browse({"hierarchy": "browse", "item_key": qobuz_key})
                list2 = result2.get("list", {}) if result2 else {}
                loaded2 = roon._api.browse_load({"hierarchy": "browse", "count": list2.get("count", 0)})
                items2 = loaded2.get("items", []) if loaded2 else []
                steps.append({
                    "step": "qobuz_root",
                    "list_input_prompt": list2.get("input_prompt"),
                    "items": [
                        {
                            "title": i.get("title"),
                            "item_key": i.get("item_key"),
                            "hint": i.get("hint"),
                            "input_prompt": i.get("input_prompt"),
                        }
                        for i in items2
                    ],
                })

                # Step 3: Find Search entry
                if list2.get("input_prompt"):
                    steps.append({"step": "qobuz_has_list_input_prompt", "input_prompt": list2["input_prompt"]})

                    # Send search directly (no item_key — just input)
                    result3 = roon._api.browse_browse({"hierarchy": "browse", "input": q})
                    count3 = result3.get("list", {}).get("count", 0) if result3 else 0
                    loaded3 = roon._api.browse_load({"hierarchy": "browse", "count": min(count3, 20)})
                    items3 = loaded3.get("items", []) if loaded3 else []
                    steps.append({
                        "step": "search_results_direct",
                        "query": q,
                        "count": len(items3),
                        "items": [
                            {
                                "title": i.get("title"),
                                "subtitle": i.get("subtitle"),
                                "item_key": i.get("item_key"),
                                "hint": i.get("hint"),
                            }
                            for i in items3[:20]
                        ],
                    })
                else:
                    # Look for a "Search" item to click
                    search_found = False
                    for item2 in items2:
                        title_lower = (item2.get("title") or "").lower()
                        if any(kw in title_lower for kw in ("search", "zoeken", "suche", "rechercher")):
                            result3 = roon._api.browse_browse({"hierarchy": "browse", "item_key": item2["item_key"]})
                            list3 = result3.get("list", {}) if result3 else {}
                            steps.append({
                                "step": "search_entry",
                                "title": item2["title"],
                                "list_input_prompt": list3.get("input_prompt"),
                            })

                            if list3.get("input_prompt"):
                                result4 = roon._api.browse_browse({"hierarchy": "browse", "input": q})
                                count4 = result4.get("list", {}).get("count", 0) if result4 else 0
                                loaded4 = roon._api.browse_load({"hierarchy": "browse", "count": min(count4, 20)})
                                items4 = loaded4.get("items", []) if loaded4 else []
                                steps.append({
                                    "step": "search_results_via_entry",
                                    "query": q,
                                    "count": len(items4),
                                    "items": [
                                        {
                                            "title": i.get("title"),
                                            "subtitle": i.get("subtitle"),
                                            "item_key": i.get("item_key"),
                                            "hint": i.get("hint"),
                                        }
                                        for i in items4[:20]
                                    ],
                                })
                            search_found = True
                            break

                    if not search_found:
                        # Path C: no search entry at the Qobuz root level — try "My Qobuz"
                        my_qobuz = next(
                            (i for i in items2 if "my qobuz" in (i.get("title") or "").lower()),
                            None,
                        )
                        if my_qobuz and my_qobuz.get("item_key"):
                            result_mq = roon._api.browse_browse({
                                "hierarchy": "browse",
                                "item_key": my_qobuz["item_key"],
                            })
                            list_mq = result_mq.get("list", {}) if result_mq else {}
                            loaded_mq = roon._api.browse_load({
                                "hierarchy": "browse",
                                "count": min(list_mq.get("count", 0) or 100, 100),
                            })
                            items_mq = loaded_mq.get("items", []) if loaded_mq else []
                            steps.append({
                                "step": "my_qobuz",
                                "list_input_prompt": list_mq.get("input_prompt"),
                                "items": [
                                    {
                                        "title": i.get("title"),
                                        "item_key": i.get("item_key"),
                                        "hint": i.get("hint"),
                                        "input_prompt": i.get("input_prompt"),
                                    }
                                    for i in items_mq
                                ],
                            })

                            if list_mq.get("input_prompt"):
                                # My Qobuz itself has a list-level search prompt
                                result_mqs = roon._api.browse_browse({"hierarchy": "browse", "input": q})
                                count_mqs = result_mqs.get("list", {}).get("count", 0) if result_mqs else 0
                                loaded_mqs = roon._api.browse_load({"hierarchy": "browse", "count": min(count_mqs, 20)})
                                items_mqs = loaded_mqs.get("items", []) if loaded_mqs else []
                                steps.append({
                                    "step": "search_results_via_my_qobuz_direct",
                                    "query": q,
                                    "count": len(items_mqs),
                                    "items": [
                                        {
                                            "title": i.get("title"),
                                            "subtitle": i.get("subtitle"),
                                            "item_key": i.get("item_key"),
                                            "hint": i.get("hint"),
                                        }
                                        for i in items_mqs[:20]
                                    ],
                                })
                            else:
                                # Look for a Search child inside My Qobuz
                                for item_mq in items_mq:
                                    t_lower = (item_mq.get("title") or "").lower()
                                    is_search = (
                                        item_mq.get("hint") == "input_prompt"
                                        or any(kw in t_lower for kw in ("search", "zoeken", "suche", "rechercher"))
                                    )
                                    if is_search and item_mq.get("item_key"):
                                        result_se = roon._api.browse_browse({
                                            "hierarchy": "browse",
                                            "item_key": item_mq["item_key"],
                                        })
                                        list_se = result_se.get("list", {}) if result_se else {}
                                        steps.append({
                                            "step": "my_qobuz_search_entry",
                                            "title": item_mq.get("title"),
                                            "list_input_prompt": list_se.get("input_prompt"),
                                        })
                                        if list_se.get("input_prompt"):
                                            result_sr = roon._api.browse_browse({"hierarchy": "browse", "input": q})
                                            count_sr = result_sr.get("list", {}).get("count", 0) if result_sr else 0
                                            loaded_sr = roon._api.browse_load({"hierarchy": "browse", "count": min(count_sr, 20)})
                                            items_sr = loaded_sr.get("items", []) if loaded_sr else []
                                            steps.append({
                                                "step": "search_results_via_my_qobuz_entry",
                                                "query": q,
                                                "count": len(items_sr),
                                                "items": [
                                                    {
                                                        "title": i.get("title"),
                                                        "subtitle": i.get("subtitle"),
                                                        "item_key": i.get("item_key"),
                                                        "hint": i.get("hint"),
                                                    }
                                                    for i in items_sr[:20]
                                                ],
                                            })
                                        break
                        else:
                            steps.append({"step": "my_qobuz", "error": "No 'My Qobuz' item found in Qobuz root"})

                # Final step: always test global search so the debug output shows
                # what hierarchy="search" returns for this query.
                steps.append({"step": "fallback_global_search"})
                roon._api.browse_browse({"hierarchy": "search", "input": q, "pop_all": True})
                global_result = roon._api.browse_load({"hierarchy": "search", "count": 20})
                global_items = global_result.get("items", []) if global_result else []
                steps.append({
                    "step": "global_search_results",
                    "query": q,
                    "count": len(global_items),
                    "items": [
                        {
                            "title": i.get("title"),
                            "subtitle": i.get("subtitle"),
                            "hint": i.get("hint"),
                            "item_key": i.get("item_key"),
                        }
                        for i in global_items[:20]
                    ],
                })

                return {"steps": steps}
        except Exception as e:
            return {"error": str(e), "steps": steps}

    return await asyncio.to_thread(_run)


@router.post("/roon/volume", response_model=VolumeControlResponse)
async def volume_control(request: VolumeControlRequest) -> VolumeControlResponse:
    """Control volume for a Roon zone by display name.

    Actions: set (0-100), adjust (+/-N), get, mute, unmute, toggle_mute.
    """
    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected. Retry after connection is established.")

    result = await asyncio.to_thread(
        roon_client.volume_control,
        request.zone_name,
        request.action,
        request.value,
    )
    if not result.success:
        raise HTTPException(status_code=400, detail=result.error or "Volume control failed")
    return VolumeControlResponse(**result.model_dump())


@router.post("/roon/transfer", response_model=TransferZoneResponse)
async def transfer_zone(request: TransferZoneRequest) -> TransferZoneResponse:
    """Transfer playback from one Roon zone to another."""
    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected. Retry after connection is established.")

    result = await asyncio.to_thread(
        roon_client.transfer_zone,
        request.from_zone,
        request.to_zone,
    )
    if not result.success:
        raise HTTPException(status_code=400, detail=result.error or "Zone transfer failed")
    return TransferZoneResponse(**result.model_dump())


@router.post("/roon/group", response_model=ZoneGroupingResponse)
async def zone_grouping(request: ZoneGroupingRequest) -> ZoneGroupingResponse:
    """Group, ungroup, or list zone groups."""
    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected. Retry after connection is established.")

    result = await asyncio.to_thread(
        roon_client.zone_grouping,
        request.action,
        request.zones,
    )
    if not result.success:
        raise HTTPException(status_code=400, detail=result.error or "Zone grouping failed")
    return ZoneGroupingResponse(**result.model_dump())


@router.post("/roon/radio", response_model=PlayRadioResponse)
async def play_radio(request: PlayRadioRequest) -> PlayRadioResponse:
    """Play an internet radio station in a Roon zone (fuzzy-matched by name)."""
    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected. Retry after connection is established.")

    result = await asyncio.to_thread(
        roon_client.play_radio,
        request.station,
        request.zone_id,
    )
    if not result.success:
        raise HTTPException(status_code=400, detail=result.error or "Play radio failed")
    return PlayRadioResponse(**result.model_dump())


@router.post("/roon/playlists", response_model=BrowsePlaylistsResponse)
async def browse_playlists(request: BrowsePlaylistsRequest) -> BrowsePlaylistsResponse:
    """Browse or play Roon playlists (all playlists, not just RoonSage-generated ones)."""
    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected. Retry after connection is established.")

    result = await asyncio.to_thread(
        roon_client.browse_playlists,
        request.action,
        request.playlist_name,
        request.zone_id,
    )
    if not result.success:
        raise HTTPException(status_code=400, detail=result.error or "Browse playlists failed")
    return BrowsePlaylistsResponse(**result.model_dump())


@router.post("/roon/qobuz-search", response_model=QobuzSearchResponse)
async def qobuz_search(request: QobuzSearchRequest) -> QobuzSearchResponse:
    """Search Qobuz for tracks via Roon's Browse API.

    Requires Qobuz to be configured and logged in within Roon.
    Returns empty tracks list (not an error) when Qobuz is unavailable.
    """
    from backend.qobuz_browser import check_qobuz_available, search_qobuz_tracks

    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        return QobuzSearchResponse(
            tracks=[],
            query=request.query,
            available=False,
            error="Roon not connected",
        )

    try:
        tracks = await search_qobuz_tracks(request.query, request.limit)
        # Reflect true Qobuz availability (cached; does not add an extra Browse API call
        # on every search). Returns False when Qobuz is not configured in Roon or the
        # user is not logged in — even if the search call returned an empty list for an
        # innocent "no results for this query" reason.
        qobuz_available = await check_qobuz_available()
        return QobuzSearchResponse(
            tracks=tracks,
            query=request.query,
            available=qobuz_available,
        )
    except Exception as e:
        logger.warning("Qobuz search endpoint error: %s", e)
        return QobuzSearchResponse(
            tracks=[],
            query=request.query,
            available=False,
            error=str(e),
        )


@router.get("/roon/browse-root")
async def browse_root():
    """Debug: return all top-level browse items from Roon."""
    roon = get_roon_client()
    if not roon or not roon.is_connected():
        return {"error": "Roon not connected"}

    try:
        def _do_browse():
            with roon._browse_lock:
                result = roon._api.browse_browse({
                    "hierarchy": "browse",
                    "pop_all": True,
                })
                items: list[dict] = []
                if result and result.get("list", {}).get("count", 0) > 0:
                    loaded = roon._api.browse_load({
                        "hierarchy": "browse",
                        "count": result["list"]["count"],
                    })
                    items = loaded.get("items", []) if loaded else []
                return items

        items = await asyncio.to_thread(_do_browse)
        return {
            "count": len(items),
            "items": [
                {
                    "title": i.get("title", ""),
                    "item_key": i.get("item_key", ""),
                    "hint": i.get("hint", ""),
                }
                for i in items
            ],
        }
    except Exception as e:
        logger.warning("browse_root debug endpoint error: %s", e)
        return {"error": str(e)}


@router.get("/external-art")
async def get_external_art(url: str = Query(...)):
    """Proxy external album art (e.g., Cover Art Archive) to avoid direct hotlinking."""
    parsed = urlparse(url)
    if parsed.scheme != "https":
        raise HTTPException(status_code=400, detail="Only HTTPS URLs allowed")
    hostname = parsed.hostname or ""
    allowed = any(hostname == d or hostname.endswith(f".{d}") for d in _EXTERNAL_ART_DOMAINS)
    if not allowed:
        raise HTTPException(status_code=400, detail="Domain not allowed")

    try:
        client = await _get_art_proxy_client()
        current_url = url
        for _ in range(5):
            response = await client.get(current_url, follow_redirects=False)
            if response.status_code == 200:
                return Response(
                    content=response.content,
                    media_type=response.headers.get("content-type", "image/jpeg"),
                    headers={"Cache-Control": "public, max-age=86400"},
                )
            if response.status_code in (301, 302, 303, 307, 308):
                redirect_url = response.headers.get("location", "")
                if not redirect_url:
                    break
                redirect_parsed = urlparse(redirect_url)
                redir_host = redirect_parsed.hostname or ""
                redir_allowed = (
                    redirect_parsed.scheme == "https"
                    and any(redir_host == d or redir_host.endswith(f".{d}") for d in _EXTERNAL_ART_DOMAINS)
                )
                if not redir_allowed:
                    break
                current_url = redirect_url
            else:
                break
    except Exception:
        logger.debug("External art proxy failed for url=%s", url, exc_info=True)

    raise HTTPException(status_code=404, detail="Art not available")
