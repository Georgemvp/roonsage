"""REST endpoints for Song Alchemy (v13.0) and saved profiles (v13.4)."""

from __future__ import annotations

import asyncio
import logging
from typing import Any, Literal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from backend.audio_features import alchemy, alchemy_profiles
from backend.audio_features.alchemy import SUBTRACT_WEIGHT
from backend.db import get_db_connection

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/alchemy", tags=["alchemy"])


class AlchemyMixRequest(BaseModel):
    add: list[str] = Field(..., min_length=1)
    subtract: list[str] = []
    limit: int = Field(25, ge=1, le=200)
    subtract_weight: float = Field(SUBTRACT_WEIGHT, ge=0.0, le=1.0)


class AlchemyPlayRequest(AlchemyMixRequest):
    zone_id: str
    mode: Literal["replace", "append"] = "replace"


class AlchemyTrack(BaseModel):
    item_key: str
    title: str
    artist: str
    album: str
    year: int | None = None
    genres: str | None = None
    bpm: float | None = None
    energy: float | None = None
    danceability: float | None = None
    valence: float | None = None
    instrumentalness: float | None = None
    acousticness: float | None = None
    similarity: float | None = None


class AlchemyMixResponse(BaseModel):
    target: dict[str, float] | None
    result_mean: dict[str, float] | None = None
    feature_columns: list[str]
    results: list[AlchemyTrack]
    n_pool: int


class AlchemyPlayResponse(AlchemyMixResponse):
    playback_started: bool
    zone_id: str
    queue_response: dict[str, Any] = {}


def _compute(req: AlchemyMixRequest) -> dict:
    conn = get_db_connection()
    try:
        return alchemy.compute_alchemy(
            conn, req.add, req.subtract, limit=req.limit,
            subtract_weight=req.subtract_weight,
        )
    finally:
        conn.close()


@router.post("/mix", response_model=AlchemyMixResponse)
async def mix(req: AlchemyMixRequest) -> AlchemyMixResponse:
    """Compute a sonic target from ADD/SUBTRACT and return ranked matches."""
    try:
        data = await asyncio.to_thread(_compute, req)
    except KeyError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return AlchemyMixResponse(
        target=data["target"],
        result_mean=data.get("result_mean"),
        feature_columns=data["feature_columns"],
        results=[AlchemyTrack(**t) for t in data["results"]],
        n_pool=data["n_pool"],
    )


@router.post("/play", response_model=AlchemyPlayResponse)
async def play(req: AlchemyPlayRequest) -> AlchemyPlayResponse:
    """Compute the mix and queue the results to Roon."""
    try:
        data = await asyncio.to_thread(_compute, req)
    except KeyError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    from backend.roon_client import get_roon_client  # noqa: PLC0415

    client = get_roon_client()
    if client is None or not client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")

    item_keys = [t["item_key"] for t in data["results"]]
    try:
        result = await asyncio.to_thread(
            client.play_tracks, req.zone_id, item_keys, req.mode
        )
        started = bool(getattr(result, "success", False))
        payload = result.model_dump() if hasattr(result, "model_dump") else {}
    except Exception as exc:
        logger.exception("Alchemy playback failed")
        started = False
        payload = {"error": str(exc)}

    return AlchemyPlayResponse(
        target=data["target"],
        result_mean=data.get("result_mean"),
        feature_columns=data["feature_columns"],
        results=[AlchemyTrack(**t) for t in data["results"]],
        n_pool=data["n_pool"],
        playback_started=started,
        zone_id=req.zone_id,
        queue_response=payload,
    )


# ---------------------------------------------------------------------------
# Saved profiles (v13.4)
# ---------------------------------------------------------------------------


class SaveProfileRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=120)
    zone_id: str | None = None
    add_track_ids: list[str] = Field(..., min_length=1)
    subtract_track_ids: list[str] = []


class GenerateProfileRequest(BaseModel):
    limit: int = Field(25, ge=1, le=200)
    zone_id: str | None = None
    play: bool = False
    mode: Literal["replace", "append"] = "replace"


class SurpriseRequest(BaseModel):
    zone_id: str | None = None
    zone_name: str | None = None
    limit: int = Field(25, ge=1, le=200)
    play: bool = False
    mode: Literal["replace", "append"] = "replace"


def _resolve_zone_name(zone_id: str) -> str | None:
    """Best-effort zone_id → display_name lookup via the live Roon client."""
    try:
        from backend.roon_client import get_roon_client  # noqa: PLC0415
        client = get_roon_client()
        if client is None or not client.is_connected():
            return None
        for z in client.get_zones():
            if z.get("zone_id") == zone_id:
                return z.get("display_name")
    except Exception:
        return None
    return None


async def _play_results(
    zone_id: str, item_keys: list[str], mode: str
) -> dict[str, Any]:
    """Queue ``item_keys`` to a Roon zone — returns a structured payload."""
    from backend.roon_client import get_roon_client  # noqa: PLC0415
    client = get_roon_client()
    if client is None or not client.is_connected():
        return {"playback_started": False, "error": "Roon not connected"}
    try:
        result = await asyncio.to_thread(
            client.play_tracks, zone_id, item_keys, mode
        )
        started = bool(getattr(result, "success", False))
        payload = result.model_dump() if hasattr(result, "model_dump") else {}
    except Exception as exc:
        logger.exception("Alchemy-profile playback failed")
        return {"playback_started": False, "error": str(exc)}
    return {"playback_started": started, "queue_response": payload}


@router.get("/profiles")
async def list_profiles() -> list[dict[str, Any]]:
    """Return every saved Alchemy profile (most-recently updated first)."""
    def _run() -> list[dict[str, Any]]:
        conn = get_db_connection()
        try:
            return alchemy_profiles.list_profiles(conn)
        finally:
            conn.close()
    return await asyncio.to_thread(_run)


@router.post("/profiles", status_code=201)
async def create_profile(req: SaveProfileRequest) -> dict[str, Any]:
    """Compute and persist a new Alchemy profile from a current selection."""
    def _run() -> dict[str, Any]:
        conn = get_db_connection()
        try:
            return alchemy_profiles.save_profile(
                conn,
                name=req.name,
                zone_id=req.zone_id,
                add_track_ids=req.add_track_ids,
                subtract_track_ids=req.subtract_track_ids,
            )
        finally:
            conn.close()
    try:
        return await asyncio.to_thread(_run)
    except KeyError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@router.delete("/profiles/{profile_id}", status_code=204)
async def remove_profile(profile_id: int) -> None:
    """Permanently delete an Alchemy profile by id."""
    def _run() -> bool:
        conn = get_db_connection()
        try:
            return alchemy_profiles.delete_profile(conn, profile_id)
        finally:
            conn.close()
    deleted = await asyncio.to_thread(_run)
    if not deleted:
        raise HTTPException(status_code=404, detail=f"Profile {profile_id} not found")


@router.post("/profiles/{profile_id}/generate")
async def generate_profile(
    profile_id: int, req: GenerateProfileRequest | None = None
) -> dict[str, Any]:
    """Apply a saved profile to the library and (optionally) play the results.

    Body fields are all optional; defaults are limit=25, play=False.
    """
    req = req or GenerateProfileRequest()

    def _compute() -> dict[str, Any]:
        conn = get_db_connection()
        try:
            return alchemy_profiles.generate_from_profile(
                conn, profile_id, limit=req.limit
            )
        finally:
            conn.close()

    try:
        data = await asyncio.to_thread(_compute)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc

    if req.play:
        zone_id = req.zone_id or data.get("zone_id")
        if not zone_id:
            data["playback_started"] = False
            data["playback_error"] = (
                "No zone bound to this profile — set zone_id on the profile "
                "or pass zone_id in the request."
            )
        else:
            item_keys = [r["item_key"] for r in data["results"]]
            if item_keys:
                playback = await _play_results(zone_id, item_keys, req.mode)
                data.update(playback)
                data["zone_id"] = zone_id
    return data


@router.post("/surprise")
async def surprise(req: SurpriseRequest) -> dict[str, Any]:
    """Generate a playlist from recent zone listening patterns.

    Last 5 played tracks → ADD, last 5 skipped tracks → SUBTRACT. When the
    zone has no skips, the lowest-energy plays become SUBTRACT instead.
    """
    zone_name = req.zone_name
    if zone_name is None and req.zone_id:
        zone_name = _resolve_zone_name(req.zone_id)

    def _compute() -> dict[str, Any]:
        conn = get_db_connection()
        try:
            return alchemy_profiles.surprise_me(
                conn, zone_name, limit=req.limit
            )
        finally:
            conn.close()

    data = await asyncio.to_thread(_compute)
    if "error" in data:
        return data

    if req.play and req.zone_id and data.get("results"):
        item_keys = [r["item_key"] for r in data["results"]]
        playback = await _play_results(req.zone_id, item_keys, req.mode)
        data.update(playback)
        data["zone_id"] = req.zone_id
    return data
