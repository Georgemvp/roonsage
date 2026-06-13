"""REST endpoints for Sonic Fingerprint (v13.1)."""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from fastapi import APIRouter
from pydantic import BaseModel, Field

from backend.db import get_db_connection

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/sonic-fingerprint", tags=["sonic-fingerprint"])


class FingerprintProfileResponse(BaseModel):
    feature_columns: list[str]
    fingerprint: list[float]
    n_source_tracks: int


class FingerprintTrack(BaseModel):
    item_key: str
    title: str
    artist: str
    album: str
    similarity: float
    play_count: int


class FingerprintRecsResponse(BaseModel):
    fingerprint: dict[str, Any]
    results: list[FingerprintTrack]
    n_pool: int


class FingerprintPlayRequest(BaseModel):
    zone_id: str
    limit: int = Field(25, ge=1, le=200)
    mode: str = "play_now"


@router.get("/profile")
async def get_profile(top_n: int = 100) -> dict[str, Any]:
    """Return the user's sonic fingerprint computed from listening history."""
    from backend.audio_features.sonic_fingerprint import get_sonic_fingerprint  # noqa: PLC0415

    def _run() -> dict[str, Any]:
        with get_db_connection() as conn:
            return get_sonic_fingerprint(conn, top_n=top_n)

    return await asyncio.to_thread(_run)


@router.get("/recommendations")
async def get_recommendations(limit: int = 25, top_n: int = 100) -> dict[str, Any]:
    """Return library tracks ranked by similarity to the sonic fingerprint."""
    from backend.audio_features.sonic_fingerprint import (
        get_fingerprint_recommendations,  # noqa: PLC0415
    )

    def _run() -> dict[str, Any]:
        with get_db_connection() as conn:
            return get_fingerprint_recommendations(conn, top_n=top_n, limit=limit)

    return await asyncio.to_thread(_run)


@router.post("/play")
async def play_fingerprint(req: FingerprintPlayRequest) -> dict[str, Any]:
    """Fetch fingerprint recommendations and queue them on a Roon zone."""
    from backend.audio_features.sonic_fingerprint import (
        get_fingerprint_recommendations,  # noqa: PLC0415
    )
    from backend.roon_client import get_roon_client  # noqa: PLC0415

    def _get_recs() -> dict[str, Any]:
        with get_db_connection() as conn:
            return get_fingerprint_recommendations(conn, limit=req.limit)

    data = await asyncio.to_thread(_get_recs)
    if "error" in data:
        return data

    keys = [r["item_key"] for r in data["results"]]
    client = get_roon_client()
    if client is None or not client.is_connected():
        return {"error": "Roon not connected", "queued": 0}

    result = await asyncio.to_thread(client.play_tracks, req.zone_id, keys, req.mode)
    return {"queued": len(keys), "zone_id": req.zone_id, "result": str(result)}
