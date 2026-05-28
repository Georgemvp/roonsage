"""REST endpoints for CLAP text-to-audio search (v13.0)."""

from __future__ import annotations

import asyncio
import logging
from datetime import UTC, datetime
from typing import Any, Literal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from backend.audio_features import clap_search
from backend.config import get_clap_enabled
from backend.db import get_db_connection

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/clap", tags=["clap"])


class ClapAnalyzeResponse(BaseModel):
    started: bool
    message: str


class ClapStatusResponse(BaseModel):
    enabled: bool
    model_loaded: bool
    status: str
    started_at: str | None = None
    finished_at: str | None = None
    n_total: int = 0
    n_done: int = 0
    n_failed: int = 0
    error_message: str | None = None


class ClapSearchRequest(BaseModel):
    query: str = Field(..., min_length=1)
    limit: int = Field(25, ge=1, le=200)


class ClapSearchPlayRequest(ClapSearchRequest):
    zone_id: str
    mode: Literal["replace", "append"] = "replace"


class ClapTrack(BaseModel):
    item_key: str
    title: str | None = None
    artist: str | None = None
    album: str | None = None
    year: int | None = None
    similarity: float | None = None


class ClapSearchResponse(BaseModel):
    query: str
    results: list[ClapTrack]


class ClapSearchPlayResponse(ClapSearchResponse):
    playback_started: bool
    zone_id: str
    queue_response: dict[str, Any] = {}


def _require_enabled() -> None:
    if not get_clap_enabled():
        raise HTTPException(
            status_code=503,
            detail="CLAP_ENABLED=true required in the environment.",
        )


@router.post("/analyze", response_model=ClapAnalyzeResponse)
async def start_analyze() -> ClapAnalyzeResponse:
    """Request CLAP batch analysis.

    The actual work runs in the sidecar worker (``backend.worker_process``)
    because the FastAPI process is started with uvicorn ``--reload`` in dev,
    which kills any in-process or subprocess batch on every file save.

    This route just flips ``clap_runs.status`` to ``'pending'``; the worker
    polls for that and runs the batch in its own process.
    """
    _require_enabled()
    conn = get_db_connection()
    try:
        current = clap_search.get_status(conn).get("status")
        if current in ("running", "pending"):
            raise HTTPException(409, f"CLAP analysis already {current}")
        clap_search._set_state(
            conn,
            "pending",
            started_at=datetime.now(UTC).isoformat(),
            finished_at=None,
            error_message=None,
        )
    finally:
        conn.close()
    return ClapAnalyzeResponse(
        started=True,
        message="CLAP analysis queued — worker will pick it up.",
    )


@router.get("/status", response_model=ClapStatusResponse)
async def status() -> ClapStatusResponse:
    enabled = get_clap_enabled()
    conn = get_db_connection()
    try:
        s = clap_search.get_status(conn)
    finally:
        conn.close()
    return ClapStatusResponse(
        enabled=enabled,
        model_loaded=clap_search._model is not None or clap_search.get_onnx_backend() is not None,
        status=s.get("status", "idle"),
        started_at=s.get("started_at"),
        finished_at=s.get("finished_at"),
        n_total=s.get("n_total") or 0,
        n_done=s.get("n_done") or 0,
        n_failed=s.get("n_failed") or 0,
        error_message=s.get("error_message"),
    )


@router.post("/search", response_model=ClapSearchResponse)
async def search(req: ClapSearchRequest) -> ClapSearchResponse:
    _require_enabled()
    if clap_search.get_model() is None:
        raise HTTPException(503, "CLAP model could not be loaded")

    def _do_search():
        conn = get_db_connection()
        try:
            return clap_search.search_by_text(conn, req.query, req.limit)
        finally:
            conn.close()

    results = await asyncio.to_thread(_do_search)
    return ClapSearchResponse(query=req.query, results=[ClapTrack(**r) for r in results])


@router.post("/search/play", response_model=ClapSearchPlayResponse)
async def search_and_play(req: ClapSearchPlayRequest) -> ClapSearchPlayResponse:
    inner = await search(ClapSearchRequest(query=req.query, limit=req.limit))

    from backend.roon_client import get_roon_client  # noqa: PLC0415

    client = get_roon_client()
    if client is None or not client.is_connected():
        raise HTTPException(503, "Roon not connected")

    item_keys = [t.item_key for t in inner.results]
    try:
        result = await asyncio.to_thread(
            client.play_tracks, req.zone_id, item_keys, req.mode
        )
        started = bool(getattr(result, "success", False))
        payload = result.model_dump() if hasattr(result, "model_dump") else {}
    except Exception as exc:
        logger.exception("CLAP search playback failed")
        started = False
        payload = {"error": str(exc)}

    return ClapSearchPlayResponse(
        query=req.query,
        results=inner.results,
        playback_started=started,
        zone_id=req.zone_id,
        queue_response=payload,
    )
