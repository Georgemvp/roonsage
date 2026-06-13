"""REST endpoints for Smart Queue Continuation (v13.6)."""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from backend import queue_continuation
from backend.config import (
    get_queue_continuation_config,
    save_queue_continuation_config,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/continuation", tags=["queue-continuation"])


class ContinuationSettings(BaseModel):
    enabled: bool | None = None
    track_count: int | None = Field(None, ge=3, le=50)
    zones: list[str] | None = None
    cooldown_seconds: int | None = Field(None, ge=60, le=24 * 3600)
    bpm_window: int | None = Field(None, ge=2, le=40)


class GenerateRequest(BaseModel):
    zone_id: str
    zone_name: str | None = None
    track_count: int | None = Field(None, ge=3, le=50)
    bpm_window: int | None = Field(None, ge=2, le=40)
    skip_cooldown: bool = False


@router.get("/settings")
async def get_settings() -> dict[str, Any]:
    return get_queue_continuation_config()


@router.post("/settings")
async def update_settings(body: ContinuationSettings) -> dict[str, Any]:
    updates = body.model_dump(exclude_none=True)
    if updates:
        save_queue_continuation_config(updates)
    return get_queue_continuation_config()


@router.post("/generate")
async def generate(body: GenerateRequest) -> dict[str, Any]:
    """Manually trigger a continuation for a zone."""
    try:
        result = await queue_continuation.trigger_continuation(
            body.zone_id,
            zone_name=body.zone_name,
            track_count=body.track_count,
            bpm_window=body.bpm_window,
            skip_cooldown=body.skip_cooldown,
        )
    except Exception as exc:
        logger.exception("manual continuation failed")
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    return result


@router.get("/log")
async def get_log(limit: int = 20) -> list[dict[str, Any]]:
    limit = max(1, min(limit, 200))
    return await asyncio.to_thread(queue_continuation.get_recent_runs, limit)
