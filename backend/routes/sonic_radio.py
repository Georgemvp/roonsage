"""REST endpoints for Sonic Radio (v13.3)."""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from backend.audio_features import sonic_radio as sr

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/sonic-radio", tags=["sonic-radio"])


# ---------------------------------------------------------------------------
# Pydantic models
# ---------------------------------------------------------------------------


class StartRequest(BaseModel):
    zone_id: str
    discovery_ratio: float | None = Field(None, ge=0.0, le=1.0)
    queue_ahead: int | None = Field(None, ge=1, le=50)
    refresh_interval: int | None = Field(None, ge=1, le=100)
    play: bool = False
    mode: str = "replace"


class StopRequest(BaseModel):
    zone_id: str


class SkipRequest(BaseModel):
    zone_id: str
    track_id: str


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.post("/start")
async def start_radio(req: StartRequest) -> dict[str, Any]:
    """Start (or restart) a Sonic Radio session on a Roon zone."""
    if sr.get_session(req.zone_id):
        # Reset the existing session by closing it first — keeps state clean.
        await sr.get_session(req.zone_id).stop()

    config: dict[str, Any] = {}
    if req.discovery_ratio is not None:
        config["discovery_ratio"] = req.discovery_ratio
    if req.queue_ahead is not None:
        config["queue_ahead"] = req.queue_ahead
    if req.refresh_interval is not None:
        config["refresh_interval"] = req.refresh_interval

    session = sr.SonicRadio(zone_id=req.zone_id, config=config)
    try:
        first_batch = await session.start()
    except RuntimeError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    sr.register_session(session)

    queued = False
    roon_result: dict[str, Any] | None = None
    if req.play:
        from backend.roon_client import get_roon_client  # noqa: PLC0415

        client = get_roon_client()
        if client is None or not client.is_connected():
            raise HTTPException(status_code=503, detail="Roon not connected")
        item_keys = [t["item_key"] for t in first_batch.get("tracks", [])]
        if item_keys:
            result = await asyncio.to_thread(
                client.play_tracks, req.zone_id, item_keys, req.mode
            )
            queued = bool(getattr(result, "success", False))
            try:
                roon_result = result.model_dump()
            except Exception:
                roon_result = {"success": queued}

    return {
        **first_batch,
        "queued": queued,
        "roon_result": roon_result,
        "stats": session.stats(),
    }


@router.post("/stop")
async def stop_radio(req: StopRequest) -> dict[str, Any]:
    """Stop an active Sonic Radio session and return final stats."""
    session = sr.get_session(req.zone_id)
    if session is None:
        raise HTTPException(
            status_code=404, detail=f"No Sonic Radio active on zone {req.zone_id!r}"
        )
    return await session.stop()


@router.get("/status")
async def status_radio() -> dict[str, Any]:
    """List every active Sonic Radio session and their stats."""
    sessions = sr.list_sessions()
    return {"n_active": len(sessions), "sessions": sessions}


@router.post("/skip")
async def skip_radio(req: SkipRequest) -> dict[str, Any]:
    """Register skip feedback for a track in a running session."""
    session = sr.get_session(req.zone_id)
    if session is None:
        raise HTTPException(
            status_code=404, detail=f"No Sonic Radio active on zone {req.zone_id!r}"
        )
    return await session.skip_feedback(req.track_id)


@router.post("/next")
async def next_radio(req: StopRequest, count: int = 5) -> dict[str, Any]:
    """Pull the next batch of tracks from a running session."""
    session = sr.get_session(req.zone_id)
    if session is None:
        raise HTTPException(
            status_code=404, detail=f"No Sonic Radio active on zone {req.zone_id!r}"
        )
    tracks = await session.next_tracks(count)
    return {
        "tracks": tracks,
        "stats": session.stats(),
    }
