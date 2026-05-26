"""REST endpoints for Song Alchemy (v13.0)."""

from __future__ import annotations

import logging
from typing import Any, Literal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from backend.audio_features import alchemy
from backend.db import get_db_connection

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/alchemy", tags=["alchemy"])


class AlchemyMixRequest(BaseModel):
    add: list[str] = Field(..., min_length=1)
    subtract: list[str] = []
    limit: int = Field(25, ge=1, le=200)


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
            conn, req.add, req.subtract, limit=req.limit
        )
    finally:
        conn.close()


@router.post("/mix", response_model=AlchemyMixResponse)
async def mix(req: AlchemyMixRequest) -> AlchemyMixResponse:
    """Compute a sonic target from ADD/SUBTRACT and return ranked matches."""
    try:
        data = _compute(req)
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
        data = _compute(req)
    except KeyError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    import asyncio  # noqa: PLC0415

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
