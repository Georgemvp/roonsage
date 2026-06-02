"""REST endpoints for the daily Circadian Auto-Playlists (v13.6).

Distinct from /api/circadian (the audio-feature hourly profile). These
endpoints expose the 3-times-a-day generated set and its settings.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from fastapi import APIRouter, BackgroundTasks
from pydantic import BaseModel, Field

from backend import circadian_auto
from backend.config import get_circadian_auto_config, save_circadian_auto_config

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/circadian-auto", tags=["circadian-auto"])


class CircadianSettings(BaseModel):
    enabled: bool | None = None
    zone: str | None = None
    schedule_hour: int | None = Field(None, ge=0, le=23)
    track_count: int | None = Field(None, ge=5, le=100)
    queue_morning: bool | None = None


class GenerateRequest(BaseModel):
    track_count: int = Field(25, ge=5, le=100)
    queue_morning_to_zone: str | None = None


@router.get("/today")
async def get_today() -> dict[str, Any]:
    """Return today's generated morning/afternoon/evening playlists."""
    return await asyncio.to_thread(circadian_auto.get_today_circadian)


@router.get("/recent")
async def get_recent(days: int = 7) -> list[dict[str, Any]]:
    """List recent circadian playlists, newest first."""
    days = max(1, min(days, 60))
    return await asyncio.to_thread(circadian_auto.get_recent_circadian, days)


@router.get("/settings")
async def get_settings() -> dict[str, Any]:
    return get_circadian_auto_config()


@router.post("/settings")
async def update_settings(body: CircadianSettings) -> dict[str, Any]:
    updates = body.model_dump(exclude_none=True)
    if updates:
        save_circadian_auto_config(updates)
    return get_circadian_auto_config()


_generation_running: bool = False


@router.post("/generate")
async def generate_now(
    background_tasks: BackgroundTasks,
    body: GenerateRequest | None = None,
) -> dict[str, Any]:
    """Kick off today's playlist generation in the background and return immediately.

    Poll GET /today to see results as each block completes.
    """
    global _generation_running  # noqa: PLW0603
    if _generation_running:
        return {"status": "already_running"}

    if body is None:
        body = GenerateRequest()
    cfg = get_circadian_auto_config()
    zone = body.queue_morning_to_zone
    if zone is None and cfg.get("queue_morning") and cfg.get("zone"):
        zone = cfg["zone"]

    track_count = body.track_count

    async def _run() -> None:
        global _generation_running  # noqa: PLW0603
        _generation_running = True
        try:
            await circadian_auto.run_daily_circadian(
                queue_morning_to_zone=zone,
                track_count=track_count,
            )
        except Exception as exc:
            logger.exception("circadian background generate failed: %s", exc)
        finally:
            _generation_running = False

    background_tasks.add_task(_run)
    return {"status": "started"}
