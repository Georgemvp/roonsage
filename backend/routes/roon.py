"""Roon zone, queue, and art proxy endpoints."""

import asyncio
import logging
from urllib.parse import urlparse

import httpx
from fastapi import APIRouter, HTTPException, Query, Response

from backend.models import (
    PlayQueueRequest,
    PlayQueueResponse,
    QueueAppendRequest,
    QueueAppendResponse,
    RoonZoneInfo,
    TransportControlRequest,
    TransportControlResponse,
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
    if not result["success"]:
        raise HTTPException(status_code=500, detail=result.get("error", "Queue failed"))
    return PlayQueueResponse(**result)


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

    if not result.get("success"):
        raise HTTPException(status_code=500, detail=result.get("error", "Queue append failed"))

    return QueueAppendResponse(
        success=True,
        tracks_added=result.get("tracks_queued", 0),
        tracks_skipped=result.get("tracks_skipped", 0),
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
    """Send a transport command (play/pause/stop/next/previous) to a Roon zone."""
    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")

    result = await asyncio.to_thread(
        roon_client.transport_control,
        request.zone_id,
        request.action,
    )
    if not result["success"]:
        raise HTTPException(status_code=400, detail=result.get("error", "Transport command failed"))
    return TransportControlResponse(**result)


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
