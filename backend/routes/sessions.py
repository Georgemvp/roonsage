"""REST endpoints for Listening Session Summaries (v13.6 / Journal view)."""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from backend import session_summarizer
from backend.config import get_session_summary_config, save_session_summary_config

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/sessions", tags=["sessions"])


class SessionSettings(BaseModel):
    enabled: bool | None = None
    gap_minutes: int | None = Field(None, ge=5, le=360)
    min_tracks: int | None = Field(None, ge=1, le=50)
    delay_minutes: int | None = Field(None, ge=0, le=60)


@router.get("")
async def list_sessions(limit: int = 30, offset: int = 0) -> dict[str, Any]:
    limit = max(1, min(limit, 200))
    offset = max(0, offset)
    return await asyncio.to_thread(session_summarizer.list_sessions, limit, offset)


@router.get("/stats")
async def get_stats() -> dict[str, Any]:
    return await asyncio.to_thread(session_summarizer.session_stats)


@router.get("/settings")
async def get_settings() -> dict[str, Any]:
    return get_session_summary_config()


@router.post("/settings")
async def update_settings(body: SessionSettings) -> dict[str, Any]:
    updates = body.model_dump(exclude_none=True)
    if updates:
        save_session_summary_config(updates)
    return get_session_summary_config()


@router.post("/detect")
async def detect_now() -> dict[str, Any]:
    """Force a session-detection pass."""
    n = await asyncio.to_thread(session_summarizer.detect_sessions)
    return {"inserted": n}


@router.post("/{session_id}/summarize")
async def summarize_now(session_id: int) -> dict[str, Any]:
    try:
        return await session_summarizer.summarize_session(session_id)
    except Exception as exc:
        logger.exception("summarize_session(%d) failed", session_id)
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@router.get("/{session_id}")
async def get_one(session_id: int) -> dict[str, Any]:
    session = await asyncio.to_thread(session_summarizer.get_session, session_id)
    if session is None:
        raise HTTPException(status_code=404, detail=f"Session {session_id} not found")
    return session
