"""REST endpoints for the circadian audio-feature profile (v13.4)."""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from backend.audio_features import circadian
from backend.db import get_db_connection

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/circadian", tags=["circadian"])


class CircadianTrack(BaseModel):
    item_key: str
    title: str
    artist: str
    album: str
    year: int | None = None
    genres: str | None = None
    energy: float | None = None
    danceability: float | None = None
    valence: float | None = None
    instrumentalness: float | None = None
    acousticness: float | None = None
    match: float
    distance: float


class CircadianPlayRequest(BaseModel):
    zone_id: str
    hour: int | None = Field(None, ge=0, le=23)
    limit: int = Field(25, ge=1, le=200)
    mode: str = "replace"


@router.get("/profile")
async def get_profile() -> dict[str, Any]:
    """Return the user's 24-hour audio-feature listening profile."""
    def _run() -> dict[str, Any]:
        conn = get_db_connection()
        try:
            return circadian.get_circadian_profile(conn)
        finally:
            conn.close()
    return await asyncio.to_thread(_run)


@router.get("/adaptive")
async def get_adaptive(zone_name: str | None = None) -> dict[str, Any]:
    """Return the skip-aware adjusted 24-hour targets (optionally per zone)."""
    def _run() -> dict[str, Any]:
        conn = get_db_connection()
        try:
            return circadian.get_adaptive_targets(conn, zone_name=zone_name)
        finally:
            conn.close()
    return await asyncio.to_thread(_run)


@router.get("/playlist")
async def get_playlist(hour: int, limit: int = 25) -> dict[str, Any]:
    """Generate a playlist matching the audio profile of a specific hour (0-23)."""
    if hour < 0 or hour > 23:
        raise HTTPException(status_code=400, detail="hour must be in 0..23")
    if limit < 1 or limit > 200:
        raise HTTPException(status_code=400, detail="limit must be in 1..200")

    def _run() -> dict[str, Any]:
        conn = get_db_connection()
        try:
            return circadian.get_circadian_playlist(conn, hour=hour, limit=limit)
        finally:
            conn.close()
    return await asyncio.to_thread(_run)


@router.get("/current")
async def get_current_playlist(limit: int = 25) -> dict[str, Any]:
    """Generate a playlist tuned to the user's listening pattern for *right now*."""
    hour = datetime.now().hour
    return await get_playlist(hour=hour, limit=limit)


@router.post("/recalculate")
async def recalculate_profile() -> dict[str, Any]:
    """Recompute the profile from the freshest listening_history data.

    The profile is computed on-demand on every request, so this is mostly a
    sanity-check endpoint: it returns the current profile and the count of
    listening_history rows that contributed to it.
    """
    def _run() -> dict[str, Any]:
        conn = get_db_connection()
        try:
            profile = circadian.get_circadian_profile(conn)
            row = conn.execute(
                """
                SELECT COUNT(*) AS n
                  FROM listening_history lh
                  JOIN tracks t
                    ON LOWER(lh.track_title) = LOWER(t.title)
                   AND LOWER(lh.artist) = LOWER(t.artist)
                  JOIN track_audio_features taf
                    ON taf.item_key = t.item_key
                 WHERE lh.skipped = 0
                """
            ).fetchone()
            return {
                "profile": profile,
                "n_listenable_rows": int(row["n"] or 0) if row else 0,
            }
        finally:
            conn.close()
    return await asyncio.to_thread(_run)


@router.post("/play")
async def play_current(req: CircadianPlayRequest) -> dict[str, Any]:
    """Generate a circadian playlist and queue it on a zone."""
    hour = req.hour if req.hour is not None else datetime.now().hour

    def _compute() -> dict[str, Any]:
        conn = get_db_connection()
        try:
            return circadian.get_circadian_playlist(conn, hour=hour, limit=req.limit)
        finally:
            conn.close()

    data = await asyncio.to_thread(_compute)
    if data.get("error"):
        raise HTTPException(status_code=400, detail=data["error"])

    item_keys = [r["item_key"] for r in data.get("results", []) if r.get("item_key")]
    if not item_keys:
        raise HTTPException(status_code=404, detail="No tracks generated for hour")

    from backend.roon_client import get_roon_client  # noqa: PLC0415
    client = get_roon_client()
    if client is None or not client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")
    try:
        result = await asyncio.to_thread(
            client.play_tracks, req.zone_id, item_keys, req.mode
        )
        started = bool(getattr(result, "success", False))
        payload = result.model_dump() if hasattr(result, "model_dump") else {}
    except Exception as exc:
        logger.exception("Circadian playback failed")
        return {**data, "playback_started": False, "error": str(exc)}

    return {**data, "playback_started": started, "queue_response": payload}
