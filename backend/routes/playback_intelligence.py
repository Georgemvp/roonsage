"""Smart playback intelligence (v13.3): smart shuffle + smart radio.

Routes
------
POST /api/playback/smart-shuffle    reorder a list of item_keys
POST /api/playback/smart-radio      build a cluster-hopping radio queue
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from backend.audio_features.smart_shuffle import smart_radio, smart_shuffle

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/playback", tags=["playback-intelligence"])


# ---------------------------------------------------------------------------
# Pydantic models
# ---------------------------------------------------------------------------


class SmartShuffleRequest(BaseModel):
    item_keys: list[str] = Field(..., min_length=1)


class SmartShuffleResponse(BaseModel):
    ordered_keys: list[str]
    n_input: int
    n_output: int


class SmartRadioRequest(BaseModel):
    zone_id: str
    duration_minutes: int = Field(60, ge=1, le=720)
    seed_item_key: str | None = None
    play: bool = False
    mode: str = "replace"


class SmartRadioTrack(BaseModel):
    item_key: str
    title: str | None = None
    artist: str | None = None
    album: str | None = None
    cluster_id: int | None = None


class SmartRadioResponse(BaseModel):
    n_tracks: int
    duration_minutes: int
    tracks: list[SmartRadioTrack]
    queued: bool = False
    zone_id: str | None = None
    roon_result: dict[str, Any] | None = None


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.post("/smart-shuffle", response_model=SmartShuffleResponse)
async def smart_shuffle_endpoint(req: SmartShuffleRequest) -> SmartShuffleResponse:
    """Reorder a track list so consecutive tracks come from different clusters."""
    ordered = await smart_shuffle(req.item_keys)
    return SmartShuffleResponse(
        ordered_keys=ordered,
        n_input=len(req.item_keys),
        n_output=len(ordered),
    )


@router.post("/smart-radio", response_model=SmartRadioResponse)
async def smart_radio_endpoint(req: SmartRadioRequest) -> SmartRadioResponse:
    """Build (and optionally play) a cluster-hopping radio queue."""
    tracks = await smart_radio(
        req.zone_id, req.duration_minutes, seed_item_key=req.seed_item_key
    )
    if not tracks:
        raise HTTPException(
            status_code=404,
            detail=(
                "Could not build a smart radio queue. Check that clustering has "
                "run and that the seed track is in a non-noise cluster."
            ),
        )

    queued = False
    roon_result: dict[str, Any] | None = None
    if req.play:
        from backend.roon_client import get_roon_client  # noqa: PLC0415

        client = get_roon_client()
        if client is None or not client.is_connected():
            raise HTTPException(status_code=503, detail="Roon not connected")
        item_keys = [t["item_key"] for t in tracks]
        result = await asyncio.to_thread(
            client.play_tracks, req.zone_id, item_keys, req.mode
        )
        queued = bool(getattr(result, "success", False))
        try:
            roon_result = result.model_dump()
        except Exception:
            roon_result = {"success": queued}

    return SmartRadioResponse(
        n_tracks=len(tracks),
        duration_minutes=req.duration_minutes,
        tracks=[SmartRadioTrack(**t) for t in tracks],
        queued=queued,
        zone_id=req.zone_id,
        roon_result=roon_result,
    )
